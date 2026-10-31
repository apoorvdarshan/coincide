import CoincideRemoteKit
import SwiftUI

/// A bot's character, drawn by the same code as on the Mac.
struct BotAvatarImage: View {
    let avatar: RemoteBotAvatar?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let avatar {
                Canvas { context, canvasSize in
                    context.withCGContext { cg in
                        BotArtwork.draw(
                            avatar.artCharacter, tint: avatar.artTint, in: cg, rect: CGRect(origin: .zero, size: canvasSize))
                    }
                }
            } else {
                // A Mac from before bot characters.
                Image(systemName: "face.smiling.inverse")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Opening a bot as the Mac does: its latest conversation, or a new one when it has none.
@MainActor
enum BotOpening {
    static func open(_ bot: RemoteBot, client: RemoteClient, navigator: Navigator) async {
        if let latest = bot.threadIDs.first {
            navigator.push(.thread(latest))
        } else if let id = await client.newBotConversation(bot.id) {
            navigator.push(.thread(id))
        }
    }
}

/// The Mac's bots: tap one to talk to it.
struct BotsView: View {
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var editing: BotEditorView.Target?
    @State private var deleting: RemoteBot?

    var body: some View {
        let bots = client.workspace.bots ?? []
        List {
            ConnectionStatusRow()
                .listRowBackground(Color.clear)
            ForEach(bots) { bot in
                Button { Task { await BotOpening.open(bot, client: client, navigator: navigator) } } label: {
                    BotRow(bot: bot)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(bot) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = bot } label: { Label("Delete", systemImage: "trash") }
                    Button { editing = .edit(bot) } label: { Label("Edit", systemImage: "pencil") }
                        .tint(.gray)
                }
                .swipeActions(edge: .leading) {
                    Button { Task { await newConversation(bot) } } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }
                    .tint(.indigo)
                }
            }
        }
        .overlay {
            if bots.isEmpty, client.isConnected {
                ContentUnavailableView {
                    Label("No Bots", systemImage: "face.smiling")
                } description: {
                    Text(client.workspace.bots == nil
                        ? "Update Coincide on your Mac to use bots here."
                        : "A bot is an assistant you set up once and talk to anytime.")
                } actions: {
                    if client.workspace.bots != nil {
                        Button("New Bot") { editing = .new }
                            .prominentButton()
                    }
                }
            }
        }
        .themedList(theme)
        .refreshable { await client.refreshWorkspace() }
        .navigationTitle("Bots")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = .new } label: { Label("New Bot", systemImage: "plus") }
                    .disabled(!client.isConnected || client.workspace.bots == nil)
            }
        }
        .sheet(item: $editing) { target in BotEditorView(target: target) }
        .modifier(BotDeletion(bot: $deleting))
    }

    @ViewBuilder
    private func menu(_ bot: RemoteBot) -> some View {
        Button { Task { await newConversation(bot) } } label: {
            Label("New Conversation", systemImage: "square.and.pencil")
        }
        .disabled(!client.isConnected)
        Button { navigator.push(.bot(bot.id)) } label: {
            Label("Past Conversations", systemImage: "clock")
        }
        Divider()
        Button { editing = .edit(bot) } label: { Label("Edit…", systemImage: "pencil") }
        Button(role: .destructive) { deleting = bot } label: { Label("Delete…", systemImage: "trash") }
    }

    private func newConversation(_ bot: RemoteBot) async {
        if let id = await client.newBotConversation(bot.id) { navigator.push(.thread(id)) }
    }
}

/// A bot with its latest conversation, or an invitation to start one.
struct BotRow: View {
    let bot: RemoteBot
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme

    var body: some View {
        let latest = bot.threadIDs.first.flatMap { client.summary($0) }
        HStack(spacing: 12) {
            BotAvatarImage(avatar: bot.avatar, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.body.weight(latest?.unseen != nil ? .semibold : .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(latest.map { $0.title } ?? String(localized: "Say hello"))
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let latest {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(latest.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                    if latest.needsUser {
                        Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
                    } else if latest.isRunning {
                        ProgressView().controlSize(.mini)
                    } else if latest.unseen != nil {
                        Circle().fill(latest.unseen == "failed" ? .red : .green).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the latest conversation"))
    }
}

/// A bot's conversations, newest first.
struct BotConversationsView: View {
    let botID: UUID
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator
    @Environment(\.theme) private var theme
    @State private var editing: BotEditorView.Target?

    var body: some View {
        let bot = client.workspace.bots?.first { $0.id == botID }
        let threads = (bot?.threadIDs ?? []).compactMap { client.summary($0) }
        List {
            if let bot {
                Section {
                    VStack(spacing: 10) {
                        BotAvatarImage(avatar: bot.avatar, size: 96)
                        Text(bot.name).font(.title2.weight(.semibold))
                        if let model = bot.selection?.modelName {
                            Text(model).font(.subheadline).foregroundStyle(theme.secondaryInk)
                        }
                        Button("New Conversation") {
                            Task { if let id = await client.newBotConversation(botID) { navigator.push(.thread(id)) } }
                        }
                        .prominentButton()
                        .disabled(!client.isConnected)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            if !threads.isEmpty {
                Section("Conversations") {
                    ForEach(threads) { thread in
                        NavigationLink(value: Route.thread(thread.id)) { ThreadRow(thread: thread) }
                    }
                }
            }
        }
        .themedList(theme)
        .navigationTitle(bot?.name ?? String(localized: "Bot"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let bot {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = .edit(bot) } label: { Label("Edit", systemImage: "pencil") }
                }
            }
        }
        .sheet(item: $editing) { target in BotEditorView(target: target) }
    }
}

/// Asks before deleting a bot, and whether its conversations go with it or stay as chats, as on the Mac.
struct BotDeletion: ViewModifier {
    @Binding var bot: RemoteBot?
    @Environment(RemoteClient.self) private var client

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete “\(bot?.name ?? "")”?", isPresented: Binding(get: { bot != nil }, set: { if !$0 { bot = nil } }),
            titleVisibility: .visible
        ) {
            if let bot {
                if bot.threadIDs.isEmpty {
                    Button("Delete Bot", role: .destructive) { delete(bot, conversations: false) }
                } else {
                    Button("Keep Conversations as Chats") { delete(bot, conversations: false) }
                    Button("Delete Conversations Too", role: .destructive) { delete(bot, conversations: true) }
                }
            }
            Button("Cancel", role: .cancel) { bot = nil }
        } message: {
            Text("Files on your Mac are not changed.")
        }
    }

    private func delete(_ target: RemoteBot, conversations: Bool) {
        bot = nil
        Task { await client.deleteBot(target.id, deletingConversations: conversations) }
    }
}

/// Creates or edits a bot: its character and color, name, instructions, and the agent its conversations start with.
struct BotEditorView: View {
    enum Target: Identifiable {
        case new
        case edit(RemoteBot)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let bot): bot.id.uuidString
            }
        }
    }

    let target: Target
    @Environment(RemoteClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var character = BotArtwork.Character.brulee
    @State private var tint = BotArtwork.Character.brulee.defaultTint
    @State private var persona = ""
    @State private var provider: String?
    @State private var modelID: String?
    @State private var fullAccess = false
    @State private var saving = false
    @State private var loaded = false

    private var existing: RemoteBot? {
        if case .edit(let bot) = target { return bot }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BotAvatarImage(avatar: RemoteBotAvatar(character, tint), size: 112)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    TextField(character.defaultName, text: $name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .submitLabel(.done)
                }
                Section("Character") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
                        ForEach(BotArtwork.Character.allCases, id: \.self) { option in
                            Button {
                                let followsName = name.isEmpty || name == character.defaultName
                                if tint == character.defaultTint { tint = option.defaultTint }
                                character = option
                                if followsName { name = "" }
                            } label: {
                                BotAvatarImage(avatar: RemoteBotAvatar(option, tint), size: 48)
                                    .padding(4)
                                    .background(Circle().fill(option == character ? theme.selection : .clear))
                                    .overlay(Circle().strokeBorder(option == character ? theme.ink : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(option.defaultName))
                            .accessibilityAddTraits(option == character ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
                        ForEach(BotArtwork.Tint.allCases, id: \.self) { option in
                            let color = BotArtwork.color(option)
                            Button { tint = option } label: {
                                Circle()
                                    .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue))
                                    .frame(width: 32, height: 32)
                                    .overlay(Circle().strokeBorder(theme.ink, lineWidth: option == tint ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(Self.name(of: option)))
                            .accessibilityAddTraits(option == tint ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    TextField("What it’s like and how it works", text: $persona, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("The agent gets these at the start of each conversation. They never appear in the transcript.")
                }
                Section("Agent") {
                    Picker("Agent", selection: $provider) {
                        ForEach(client.workspace.providers) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                    if let models = client.provider(provider ?? "")?.models, !models.isEmpty {
                        Picker("Model", selection: $modelID) {
                            ForEach(models) { model in Text(model.name).tag(Optional(model.id)) }
                        }
                    }
                    Toggle("Full Access", isOn: $fullAccess)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.content)
            .navigationTitle(existing == nil ? "New Bot" : "Edit Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(saving || !client.isConnected)
                }
            }
            .onAppear(perform: load)
            .onChange(of: provider) { old, new in
                guard loaded, old != new else { return }
                modelID = client.provider(new ?? "")?.models.first?.id
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        if let bot = existing {
            name = bot.name
            character = bot.avatar?.artCharacter ?? .alien
            tint = bot.avatar?.artTint ?? character.defaultTint
            if name == character.defaultName { name = "" }
            persona = bot.persona ?? ""
            provider = bot.selection?.provider
            modelID = bot.selection?.modelID
            fullAccess = bot.accessMode == "fullAccess"
        } else {
            let first = client.workspace.providers.first
            provider = first?.id
            modelID = first?.models.first?.id
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let original = existing
        let draft = RemoteBotDraft(
            id: original?.id, name: name, avatar: RemoteBotAvatar(character, tint), persona: persona,
            provider: provider == original?.selection?.provider && modelID == original?.selection?.modelID ? nil : provider,
            modelID: provider == original?.selection?.provider && modelID == original?.selection?.modelID ? nil : modelID,
            accessMode: fullAccess ? "fullAccess" : "approval")
        if await client.saveBot(draft) != nil { dismiss() }
    }

    static func name(of tint: BotArtwork.Tint) -> String {
        switch tint {
        case .sunflower: String(localized: "Sunflower")
        case .tangerine: String(localized: "Tangerine")
        case .coral: String(localized: "Coral")
        case .cherry: String(localized: "Cherry")
        case .rose: String(localized: "Rose")
        case .lilac: String(localized: "Lilac")
        case .sky: String(localized: "Sky")
        case .mint: String(localized: "Mint")
        case .leaf: String(localized: "Leaf")
        case .sage: String(localized: "Sage")
        case .caramel: String(localized: "Caramel")
        }
    }
}
