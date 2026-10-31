import CoincideRemoteKit
import SwiftUI

/// A bot's character, drawn by the same code as on the Mac. It blinks while the bot works, as on the Mac.
struct BotAvatarImage: View {
    let avatar: RemoteBotAvatar?
    var size: CGFloat = 40
    /// The bot's name, which picks a character when an older Mac sends none.
    var name: String?
    var isWorking = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let look = avatar.map({ ($0.artCharacter, $0.artTint) }) ?? Self.character(named: name) {
                if isWorking, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        art(look.0, look.1, openness: Self.openness(at: context.date))
                    }
                } else {
                    art(look.0, look.1, openness: 1)
                }
            } else {
                silhouette
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func art(_ character: BotArtwork.Character, _ tint: BotArtwork.Tint, openness: CGFloat) -> some View {
        Canvas { context, canvasSize in
            context.withCGContext { cg in
                BotArtwork.draw(character, tint: tint, in: cg, rect: CGRect(origin: .zero, size: canvasSize), openness: openness)
            }
        }
    }

    /// A Mac from before bot characters, with a bot that doesn't carry a character's own name: a quiet figure in the
    /// theme's colors, like a contact without a photo.
    private var silhouette: some View {
        Circle()
            .fill(theme.selection)
            .overlay {
                Image(systemName: "person.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(theme.tertiaryInk)
                    .padding(size * 0.24)
                    .offset(y: size * 0.04)
            }
            .clipShape(Circle())
    }

    /// The character whose own name the bot has, as the Mac names a new bot after its character: an older Mac's
    /// "Brulee" still looks like Brulee.
    static func character(named name: String?) -> (BotArtwork.Character, BotArtwork.Tint)? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
            let character = BotArtwork.Character.allCases.first(where: { $0.defaultName.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return (character, character.defaultTint)
    }

    /// How open the eyes are: a quick blink every few seconds.
    static func openness(at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6)
        guard phase < 0.18 else { return 1 }
        return CGFloat(abs(phase - 0.09) / 0.09)
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
            ForEach(bots) { bot in
                BotLink(bot: bot)
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
        .sidebarList(theme)
        .overlay {
            if bots.isEmpty, client.isConnected {
                ContentUnavailableView {
                    // The Mac's own characters, not a stock symbol: the bot a new one starts as.
                    VStack(spacing: 12) {
                        HStack(spacing: -10) {
                            BotAvatarImage(avatar: RemoteBotAvatar(.teddy, .caramel), size: 56)
                            BotAvatarImage(avatar: RemoteBotAvatar(.brulee, .rose), size: 72)
                            BotAvatarImage(avatar: RemoteBotAvatar(.alien, .mint), size: 56)
                        }
                        .accessibilityHidden(true)
                        Text("No Bots").font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
                    }
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
                .foregroundStyle(theme.secondaryInk)
            }
        }
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

/// A bot in a sidebar list: tap to open its latest conversation (or start one).
struct BotLink: View {
    let bot: RemoteBot
    @Environment(RemoteClient.self) private var client
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button { Task { await BotOpening.open(bot, client: client, navigator: navigator) } } label: {
            BotRow(bot: bot)
        }
        .buttonStyle(SidebarRowButtonStyle(isSelected: navigator.isSplit && navigator.selection.map(bot.threadIDs.contains) == true))
        .sidebarRow()
    }
}

/// A bot as the Mac's sidebar shows it (`BotCell`): its character, its name and time on the first line, its latest
/// conversation below, like a conversation in a messaging app. The character blinks while the bot works; an approval
/// or a failure shows as a badge.
struct BotRow: View {
    let bot: RemoteBot
    @Environment(RemoteClient.self) private var client
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .callout) private var avatarSize: CGFloat = 36

    var body: some View {
        let conversations = bot.threadIDs.compactMap { client.summary($0) }
        let latest = conversations.first
        let status = SidebarStatus.strongest(conversations) ?? .idle
        HStack(spacing: 10) {
            BotAvatarImage(avatar: bot.avatar, size: avatarSize, name: bot.name, isWorking: status.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(bot.name)
                        .font(.callout.weight(status == .completed || status == .failed ? .semibold : .medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    accessories(status, latest: latest)
                }
                Text(latest.map { $0.title } ?? String(localized: "Say hello"))
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([bot.name, latest?.title ?? String(localized: "Say hello"), status.label].compactMap(\.self).joined(separator: ", ")))
        .accessibilityHint(Text("Opens the latest conversation"))
    }

    @ViewBuilder
    private func accessories(_ status: SidebarStatus, latest: RemoteThreadSummary?) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .approval(let count):
                StatusBadge(text: count > 1 ? String(localized: "Approval \(count)") : String(localized: "Approval"), color: .orange)
            case .question:
                StatusBadge(text: String(localized: "Question"), color: .orange)
            case .failed:
                StatusBadge(text: String(localized: "Failed"), color: .red)
            case .starting:
                ProgressView().controlSize(.mini)
            case .running(let since?):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Formatting.elapsed(since: since, now: context.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(theme.ink)
                }
            case .completed, .idle, .running(nil):
                if status == .completed { StatusDot(color: .green) }
                if let latest {
                    TimelineView(.everyMinute) { context in
                        Text(Formatting.compactAge(of: latest.updatedAt, now: context.date))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(theme.secondaryInk)
                    }
                }
            }
        }
        .fixedSize()
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
                VStack(spacing: 10) {
                    BotAvatarImage(avatar: bot.avatar, size: 88, name: bot.name)
                    Text(bot.name).font(.title3.weight(.semibold)).foregroundStyle(theme.ink)
                    if let model = bot.selection?.modelName {
                        Text(model).font(.footnote).foregroundStyle(theme.secondaryInk)
                    }
                    Button("New Conversation") {
                        Task { if let id = await client.newBotConversation(botID) { navigator.push(.thread(id)) } }
                    }
                    .prominentButton()
                    .disabled(!client.isConnected)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .sidebarRow()
            }
            if !threads.isEmpty {
                SidebarHeader(Text("Conversations")).sidebarRow()
                ForEach(threads) { thread in ThreadLink(thread: thread) }
            }
        }
        .sidebarList(theme)
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
                Group { fields }
                    .themedCards(theme)
            }
            .scrollContentBackground(.hidden)
            .background(theme.isDark ? theme.content : theme.sidebar)
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

    @ViewBuilder private var fields: some View {
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
