import AVFoundation
import AppKit
import CoincideKit
import CoincideRemoteKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Coincide Remote's view of the app: turns the store, the runner and the registry into the remote protocol's models,
/// and carries out what the phone asks through the same calls the Mac's own controls make. The Mac stays the only
/// source of truth; the adapter keeps no state of its own besides its store observation.
@MainActor
final class RemoteStoreAdapter {
    /// What the adapter needs beyond the store, runner and registry: the app-level services, as closures so tests can
    /// supply their own.
    struct Services {
        var pending: (UUID) -> (approvals: Int, questions: Int)
        var unseen: (UUID) -> String?
        var markSeen: (UUID) -> Void
        var markUnread: (UUID) -> Void
        var isSettled: (ThreadSummary) -> Bool
        var isHidden: (ThreadSummary) -> Bool
        var archive: ([UUID], Bool) -> Void
        var settle: ([UUID], Bool) -> Void
        var delete: ([UUID]) throws -> Void
        var snooze: (UUID, Date?) -> Void
        var runScript: (ProjectScript, UUID) -> Void
        var turnChanges: (UUID) -> [String: [RemoteChangedFile]]
        var isPreparingWorktree: (UUID) -> Bool
        var importImage: (Data, URL) async -> String?
        var diff: (UUID, UUID?) async throws -> RemoteDiff
        /// Why the thread can't move now, or nil.
        var moveBlocker: (UUID) -> String?
        var move: (UUID, UUID) -> Void
        /// The Mac sidebar's sorting and section order.
        var layout: () -> Layout

        struct Layout {
            var sections: [String] = SidebarSection.defaultOrder.map(\.rawValue)
            var pinned: [String] = []
            var projectSort = ProjectSort.manual
            var threadSort = ThreadSort.recentActivity
            var chatSort = ThreadSort.recentActivity
            var botSort = BotSort.manual
        }

        static var live: Services {
            Services(
                pending: { id in
                    (ThreadActivity.shared.pendingApprovalCount(id), ThreadActivity.shared.pendingQuestionCount(id))
                },
                unseen: { ThreadActivity.shared.unseen($0)?.rawValue },
                markSeen: { ThreadActivity.shared.markSeen($0) },
                markUnread: { ThreadActivity.shared.markUnread($0) },
                isSettled: { ThreadInbox.shared.isSettled($0) },
                isHidden: { ThreadSnooze.isHidden($0) || ThreadInbox.isHidden($0) },
                archive: { ThreadInbox.shared.archive($0, archived: $1) },
                settle: { ThreadInbox.shared.settle($0, settled: $1) },
                delete: { ids in
                    for id in ids { ThreadRunner.shared.shutdown(threadID: id) }
                    try ThreadInbox.shared.delete(ids)
                },
                snooze: { id, date in
                    if let date { ThreadSnooze.shared.snooze(id, until: date) } else { ThreadSnooze.shared.unsnooze(id) }
                },
                runScript: { ProjectScripts.shared.run($0, threadID: $1) },
                turnChanges: { id in
                    var result: [String: [RemoteChangedFile]] = [:]
                    for checkpoint in CheckpointService.shared.checkpoints(threadID: id) where !checkpoint.files.isEmpty {
                        result[checkpoint.userItemID.uuidString] = checkpoint.files.map(RemoteStoreAdapter.changedFile)
                    }
                    return result
                },
                isPreparingWorktree: { WorktreeService.shared.isPreparing($0) },
                importImage: { data, directory in
                    await ComposerAttachmentImporter.importImage(.data(data), into: directory)?.path
                },
                diff: { threadID, turnID in try await RemoteStoreAdapter.liveDiff(threadID: threadID, turnID: turnID) },
                moveBlocker: { ThreadActions.moveBlocker($0) },
                move: { ThreadActions.move([$0], to: $1) },
                layout: {
                    let ui = UIState.shared.values
                    return Layout(
                        sections: SidebarOrdering.sectionOrder(saved: ui.sidebarSections).map(\.rawValue), pinned: ui.pinnedThreads,
                        projectSort: ui.projectSort, threadSort: ui.threadSort, chatSort: ui.chatSort, botSort: ui.botSort)
                })
        }
    }

    /// What changed, for the server to pass on to connected phones.
    enum Change: Equatable {
        /// The sidebar: threads, projects, agents or their state.
        case workspace
        /// Settings the phone follows, such as the theme.
        case server
        /// Items of a thread were appended or changed.
        case items(UUID, [UUID])
        /// A thread's transcript must be sent again.
        case reset(UUID)
        /// A thread's turn or queue changed.
        case turn(UUID)
        /// The user saw the thread somewhere: phones remove what was posted about it.
        case clearNotifications(UUID)
    }

    let store: AppStore
    let runner: ThreadRunner
    /// What the Settings catalog needs from the running app (`RemoteSettingsCatalog`).
    var settingsServices = SettingsServices.live
    /// The global instruction files Settings › Instructions lists and edits.
    lazy var instructions = RemoteInstructions.live
    let registry: ProviderRegistry
    let services: Services
    private var token: ObservationToken?
    private var notificationTokens: [NSObjectProtocol] = []
    private var handlers: [UUID: (Change) -> Void] = [:]

    /// Largest tool output and input sent per item; the rest stays on the Mac.
    nonisolated static let maxToolText = 6_000
    nonisolated static let maxToolDetail = 8_000
    static let maxImages = 10
    static let maxImageBytes = 20 * 1024 * 1024

    init(store: AppStore = .shared, runner: ThreadRunner = .shared, registry: ProviderRegistry = .shared, services: Services = .live) {
        self.store = store
        self.runner = runner
        self.registry = registry
        self.services = services
    }

    // MARK: Observation

    /// Registers for changes. Keep the returned token; observation starts with the first handler and stops with the last.
    func observe(_ handler: @escaping (Change) -> Void) -> ObservationHandle {
        let id = UUID()
        handlers[id] = handler
        if token == nil { startObserving() }
        return ObservationHandle { [weak self] in
            guard let self else { return }
            self.handlers[id] = nil
            if self.handlers.isEmpty { self.stopObserving() }
        }
    }

    private func startObserving() {
        token = store.observe { [weak self] change in self?.handle(change) }
        let center = NotificationCenter.default
        for name in [Notification.Name.coincideThreadActivityChanged, ThreadInbox.didChange] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(.workspace) }
            })
        }
    }

    private func stopObserving() {
        token = nil
        for observer in notificationTokens { NotificationCenter.default.removeObserver(observer) }
        notificationTokens = []
    }

    /// Tells every connected phone to remove what was posted about the thread. Goes to every session, whether or not
    /// anything changes in the store, so a phone that isn't observing anything else still hears it.
    func clearNotifications(_ threadID: UUID) {
        emit(.clearNotifications(threadID))
    }

    private func emit(_ change: Change) {
        for handler in handlers.values { handler(change) }
    }

    private func handle(_ change: StoreChange) {
        switch change {
        case .projects, .threadList, .providers, .bots:
            emit(.workspace)
        case .thread(let id):
            emit(.workspace)
            emit(.turn(id))
        case .runState(let id):
            emit(.workspace)
            emit(.turn(id))
        case .settings:
            emit(.server)
            emit(.workspace)
        case .items(let id, let changed, let appended):
            if changed.isEmpty, !appended {
                emit(.reset(id))
                emit(.workspace)
            } else {
                emit(.items(id, changed))
                // An appended item moves the thread up the list.
                if appended { emit(.workspace) }
            }
        }
    }

    // MARK: Snapshots

    func serverInfo(serverID: String, name: String) -> RemoteServerInfo {
        let settings = store.settings
        return RemoteServerInfo(
            serverID: serverID, name: name,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            theme: RemoteThemeInfo(
                appearance: settings.appearance.rawValue, darkThemeID: settings.darkTheme, lightThemeID: settings.lightTheme),
            showsReasoning: settings.showReasoning, followUpBehavior: settings.followUpBehavior.rawValue,
            notifies: settings.notifyWhenInBackground, replyTypeface: settings.replyTypeface.rawValue,
            userMessageSide: settings.userMessageSide.rawValue)
    }

    /// The sidebar in the Mac's order: its sections, its project and bot sorts (Chats last), and each list's thread sort.
    func workspace(includeArchived: Bool = false) -> RemoteWorkspace {
        let layout = services.layout()
        let all = Array(store.threadSummaries.values)
        let sortedProjects = SidebarOrdering.sortedProjects(
            store.projects, by: layout.projectSort, lastActivity: SidebarOrdering.lastActivity(of: all))
        let projects = sortedProjects.map { project in
            RemoteProject(
                id: project.id, name: project.isChats ? String(localized: "Chats") : project.name,
                path: (project.path as NSString).abbreviatingWithTildeInPath, isChats: project.isChats,
                scripts: project.scripts.map { RemoteScript(id: $0.id, name: $0.name, command: $0.command, icon: $0.icon.rawValue) },
                isExpanded: project.isChats ? nil : project.isExpanded)
        }
        let byProject = Dictionary(grouping: all.filter { includeArchived || !$0.isArchived }, by: \.projectID)
        let threads = sortedProjects.flatMap { project in
            SidebarOrdering.sortedThreads(byProject[project.id] ?? [], by: project.isChats ? layout.chatSort : layout.threadSort)
        }
        let pinned = SidebarOrdering.pinnedOrder(saved: layout.pinned, pinned: threads.filter(\.isPinned))
        let bots = SidebarOrdering.sortedBots(store.bots, by: layout.botSort, lastActivity: SidebarOrdering.lastBotActivity(of: all))
        return RemoteWorkspace(
            projects: projects, threads: threads.map(summary), bots: bots.map { bot in
                RemoteBot(
                    id: bot.id, name: bot.name, projectID: store.botsProject.id,
                    threadIDs: store.conversations(of: bot.id).map(\.id),
                    avatar: RemoteBotAvatar(character: bot.avatar.shape.rawValue, tint: bot.avatar.tint.rawValue),
                    persona: bot.persona, selection: selection(bot.selection), accessMode: bot.accessMode.rawValue,
                    interactionMode: bot.interactionMode.rawValue,
                    folder: bot.folder.map { ($0 as NSString).abbreviatingWithTildeInPath })
            }, providers: providers(), sections: layout.sections,
            pinnedOrder: pinned)
    }

    func summary(_ thread: ThreadSummary) -> RemoteThreadSummary {
        let pending = services.pending(thread.id)
        return RemoteThreadSummary(
            id: thread.id, projectID: thread.projectID, title: thread.title, createdAt: thread.createdAt,
            updatedAt: thread.updatedAt, selection: selection(thread.selection), accessMode: thread.accessMode.rawValue,
            interactionMode: thread.interactionMode.rawValue, isPinned: thread.isPinned, isArchived: thread.isArchived,
            snoozedUntil: thread.snoozedUntil, isSettled: services.isSettled(thread), isHidden: services.isHidden(thread),
            branch: thread.branch, hasWorktree: thread.worktreePath != nil, isRunning: runner.isRunning(thread.id),
            isStarting: runner.isStarting(thread.id), pendingApprovals: pending.approvals, pendingQuestions: pending.questions,
            unseen: services.unseen(thread.id), queuedMessages: runner.queuedMessages(thread.id).count, hasDraft: thread.hasDraft,
            itemCount: thread.itemCount, runningSince: runner.turn(thread.id)?.startedAt,
            hasBackgroundWork: !runner.backgroundTasks(thread.id).isEmpty)
    }

    func selection(_ selection: ModelSelection) -> RemoteSelection {
        RemoteSelection(
            provider: selection.provider.rawValue, modelID: selection.modelID, modelName: registry.displayName(for: selection),
            effort: selection.effort, speed: selection.speed, accountID: selection.accountID,
            accountName: registry.accountName(for: selection))
    }

    func providers() -> [RemoteProvider] {
        registry.orderedKinds.filter { store.settings.settings(for: $0).isEnabled }.map { kind in
            RemoteProvider(
                id: kind.rawValue, name: kind.displayName, state: registry.status(kind).state.rawValue,
                accounts: registry.accounts(for: kind).map { account in
                    RemoteAccount(
                        id: account.id, name: account.name, isReady: registry.status(kind, account: account.id).state == .ready)
                },
                models: registry.pickerModels(for: kind, current: nil).map(Self.model))
        }
    }

    nonisolated static func model(_ model: ModelOption) -> RemoteModel {
        RemoteModel(
            id: model.modelID, name: model.displayName, efforts: model.efforts, defaultEffort: model.defaultEffort,
            speeds: model.speeds.map { RemoteSpeed(id: $0.id, name: $0.name, detail: $0.detail) },
            supportsImages: model.supportsImages)
    }

    nonisolated static func changedFile(_ file: ChangedFile) -> RemoteChangedFile {
        RemoteChangedFile(
            path: file.path, oldPath: file.oldPath, status: file.status.rawValue, additions: file.additions,
            deletions: file.deletions)
    }

    func turnState(_ threadID: UUID) -> RemoteTurnState {
        let turn = runner.turn(threadID)
        return RemoteTurnState(
            isRunning: turn != nil, isStarting: runner.isStarting(threadID), startedAt: turn?.startedAt,
            provider: turn?.provider.rawValue, canSteer: runner.canSteer(threadID),
            queued: runner.queuedMessages(threadID).map {
                RemoteQueuedMessage(id: $0.id, text: $0.text, imageCount: $0.imagePaths.count)
            },
            resumesAt: runner.scheduledResumes[threadID],
            backgroundTasks: runner.backgroundTasks(threadID).map { Self.backgroundTask($0.task, provider: $0.provider) })
    }

    /// A background task as the phone lists it. Titles and progress are clipped like tool text; a background
    /// command's title can be a whole script.
    nonisolated static func backgroundTask(_ task: BackgroundTask, provider: ProviderKind) -> RemoteBackgroundTask {
        let kind: RemoteBackgroundTask.Kind =
            switch task.kind {
            case .agent: .agent
            case .command: .command
            case .other: .other
            }
        return RemoteBackgroundTask(
            id: task.id, provider: provider.rawValue, title: String(task.title.prefix(maxBackgroundText)), kind: kind,
            startedAt: task.startedAt, agentType: task.agentType, progress: task.progress.map { String($0.prefix(maxBackgroundText)) })
    }

    nonisolated static let maxBackgroundText = 500

    /// The thread's newest `limit` items with its turn state, or nil when there's no such thread.
    func transcript(_ threadID: UUID, limit: Int) -> RemoteTranscript? {
        guard let summary = store.summary(threadID), let thread = store.thread(threadID) else { return nil }
        let limit = max(1, min(limit, 1_000))
        let start = max(0, thread.items.count - limit)
        let directory = store.workingDirectory(for: threadID)
        let items = thread.items[start...].enumerated().map { offset, item in remoteItem(item, index: start + offset, directory: directory) }
        return RemoteTranscript(
            thread: self.summary(summary), items: items, hasEarlier: start > 0, turn: turnState(threadID),
            turnChanges: services.turnChanges(threadID))
    }

    func items(_ threadID: UUID, before index: Int, limit: Int) -> RemoteItemPage? {
        guard let thread = store.thread(threadID) else { return nil }
        let end = max(0, min(index, thread.items.count))
        let start = max(0, end - max(1, min(limit, 1_000)))
        let directory = store.workingDirectory(for: threadID)
        let items = thread.items[start..<end].enumerated().map { offset, item in remoteItem(item, index: start + offset, directory: directory) }
        return RemoteItemPage(items: items, hasEarlier: start > 0)
    }

    /// The items with these ids, each with its index, in transcript order.
    func items(_ threadID: UUID, ids: Set<UUID>) -> (items: [RemoteItem], count: Int)? {
        guard let thread = store.thread(threadID) else { return nil }
        var result: [RemoteItem] = []
        let directory = store.workingDirectory(for: threadID)
        // Changed items are almost always among the newest.
        for index in thread.items.indices.reversed() where ids.contains(thread.items[index].id) {
            result.append(remoteItem(thread.items[index], index: index, directory: directory))
            if result.count == ids.count { break }
        }
        return (result.reversed(), thread.items.count)
    }

    /// An item with the previews the Mac's transcript shows for it: a message's attached images, and the images,
    /// video, audio and interactive pages a reply references.
    private func remoteItem(_ item: TranscriptItem, index: Int, directory: URL?) -> RemoteItem {
        var remote = Self.item(item, index: index)
        guard item.kind == .user || item.kind == .assistant else { return remote }
        remote.media = Self.media(TranscriptMediaCache.media(item, directory: directory))
        return remote
    }

    nonisolated static func media(_ media: [TranscriptMedia]) -> [RemoteMedia] {
        media.enumerated().map { index, media in
            let kind: RemoteMedia.Kind =
                switch media.kind {
                case .image: .image
                case .video: .video
                case .audio: .audio
                case .interactive: .interactive
                }
            return RemoteMedia(index: index, kind: kind, label: String(media.label.prefix(300)))
        }
    }

    /// A preview's pixels for the phone: only media the item itself references (its attachments, or what its reply
    /// links), downsampled to a thumbnail or the full size and re-encoded, so the phone can't read any other file.
    func media(_ threadID: UUID, itemID: UUID, index: Int, full: Bool) async throws -> RemoteMediaData {
        guard let thread = store.thread(threadID) else {
            throw RemoteError(.notFound, String(localized: "That thread no longer exists."))
        }
        guard let item = thread.items.first(where: { $0.id == itemID }), item.kind == .user || item.kind == .assistant else {
            throw RemoteError(.notFound, String(localized: "That preview is no longer available."))
        }
        let media = TranscriptMediaCache.media(item, directory: store.workingDirectory(for: threadID))
        guard media.indices.contains(index) else {
            throw RemoteError(.notFound, String(localized: "That preview is no longer available."))
        }
        let pixels = full ? RemoteMediaData.fullPixels : RemoteMediaData.thumbnailPixels
        let image: CGImage?
        switch media[index].kind {
        case .image: image = await MediaImageLoader.load(media[index].url, maxPixelSize: pixels)
        case .video where !full: image = await Self.firstFrame(media[index].url, maxPixelSize: pixels)
        case .video, .audio, .interactive:
            throw RemoteError(.notAllowed, String(localized: "Open it on your Mac to see it."))
        }
        guard let image, let data = Self.encode(image), data.count <= RemoteMediaData.maxBytes else {
            throw RemoteError(.failed, String(localized: "The preview couldn’t be loaded."))
        }
        return RemoteMediaData(data: data, width: image.width, height: image.height, isFull: full)
    }

    /// Suggestions for the composer's word, as the Mac's composer offers them: files in the thread's folder for `@`
    /// (`ComposerFileIndex`, which honors .gitignore), and the commands and skills its agent offers there for `/`.
    func completions(_ threadID: UUID, trigger: String, query: String) async throws -> [RemoteCompletion] {
        guard let thread = store.summary(threadID) else {
            throw RemoteError(.notFound, String(localized: "That thread no longer exists."))
        }
        let query = String(query.prefix(200))
        switch trigger {
        case "@":
            guard let root = store.workingDirectory(for: threadID) else { return [] }
            let files = await ComposerFileIndex.shared.search(query, in: root, limit: RemoteCompletion.maxResults)
            return files.map { file in
                RemoteCompletion(
                    kind: file.isDirectory ? .folder : .file, insert: ComposerTrigger.mention(file.path) + " ", title: file.name,
                    detail: file.parent.isEmpty ? nil : file.parent)
            }
        case "/":
            let commands = runner.commands(threadID, provider: thread.selection.provider)
            let matches = commands.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
                .sorted { lhs, rhs in
                    let left = lhs.name.lowercased().hasPrefix(query.lowercased())
                    let right = rhs.name.lowercased().hasPrefix(query.lowercased())
                    return left != right ? left : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            return matches.prefix(RemoteCompletion.maxResults).map { command in
                RemoteCompletion(
                    kind: command.kind == .skill ? .skill : .command, insert: "/\(command.name) ", title: "/\(command.name)",
                    detail: command.description ?? command.argumentHint)
            }
        default:
            throw RemoteError(.badRequest, "Unknown completion trigger.")
        }
    }

    /// A video's first frame, for its thumbnail. Local files only.
    @concurrent nonisolated static func firstFrame(_ url: URL?, maxPixelSize: Int) async -> CGImage? {
        guard let url, url.isFileURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try? await generator.image(at: .zero).image
    }

    /// JPEG, or PNG for a picture with transparency so its see-through parts don't turn black.
    nonisolated static func encode(_ image: CGImage) -> Data? {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    nonisolated static func item(_ item: TranscriptItem, index: Int) -> RemoteItem {
        var text = item.text
        var detail = item.detail
        var clipped = false
        if item.kind == .tool {
            if text.count > maxToolText {
                text = "…\n" + String(text.suffix(maxToolText))
                clipped = true
            }
            if let value = detail, value.count > maxToolDetail {
                detail = String(value.prefix(maxToolDetail)) + "\n…"
                clipped = true
            }
        }
        let approval = item.approval.map { approval in
            RemoteApproval(
                options: approval.options.map { RemoteApproval.Option(id: $0.id, label: $0.label, kind: $0.kind.rawValue) },
                resolution: approval.resolution, textPlaceholder: approval.textInput?.placeholder,
                acceptsText: approval.textInput != nil, responseText: approval.responseText)
        }
        let questions = item.questions.map { request in
            RemoteQuestionSet(
                title: request.title,
                questions: request.questions.map { question in
                    RemoteQuestionSet.Question(
                        id: question.id, header: question.header, prompt: question.prompt,
                        options: question.options.map { .init(label: $0.label, detail: $0.detail) },
                        allowsMultipleSelection: question.allowsMultipleSelection, allowsFreeText: question.allowsFreeText,
                        isSecret: question.isSecret)
                })
        }
        // Secret answers never leave the Mac.
        var answers = item.answers
        if let request = item.questions, answers != nil {
            for question in request.questions where question.isSecret { answers?[question.id] = ["••••••"] }
        }
        return RemoteItem(
            id: item.id, index: index, kind: RemoteItem.Kind(rawValue: item.kind.rawValue) ?? .unknown, text: text,
            title: item.title, detail: detail, category: item.category?.rawValue, status: item.status?.rawValue,
            provider: item.provider?.rawValue, modelID: item.modelID, approval: approval, questions: questions, answers: answers,
            attachments: item.attachments?.map { ($0 as NSString).lastPathComponent },
            context: item.context?.map(\.summary), steered: item.isSteered, isClipped: clipped, createdAt: item.createdAt,
            completedAt: item.completedAt)
    }

    // MARK: Actions

    private func requireThread(_ id: UUID) throws -> ThreadSummary {
        guard let thread = store.summary(id) else { throw RemoteError(.notFound, String(localized: "That thread no longer exists.")) }
        return thread
    }

    /// Sends a message as the Mac's composer does: while a turn runs it steers or queues per the follow-up setting, and
    /// approvals and questions still waiting are declined so the message redirects the agent. Returns where it went.
    func send(_ request: RemoteSendRequest) async throws -> String {
        let threadID = request.threadID
        _ = try requireThread(threadID)
        let text = request.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.images.isEmpty else {
            throw RemoteError(.badRequest, String(localized: "The message is empty."))
        }
        guard request.images.count <= Self.maxImages, request.images.allSatisfy({ $0.data.count <= Self.maxImageBytes }) else {
            throw RemoteError(.badRequest, String(localized: "Attach at most 10 images of up to 20 MB each."))
        }
        guard !services.isPreparingWorktree(threadID) else {
            throw RemoteError(.notAllowed, String(localized: "The thread’s worktree is still being created. Try again in a moment."))
        }
        var imagePaths: [String] = []
        let directory = store.directory.appendingPathComponent("attachments", isDirectory: true)
        for image in request.images {
            guard let path = await services.importImage(image.data, directory) else {
                throw RemoteError(.badRequest, String(localized: "“\(image.name)” isn’t an image Coincide can send."))
            }
            imagePaths.append(path)
        }
        let chosen = store.thread(threadID).map {
            ComposerDispatch.effective(store.followUpBehavior(of: $0), for: $0.selection.provider)
        } ?? store.settings.followUpBehavior
        let behavior = ComposerDispatch.followUpBehavior(chosen, approvalShown: !runner.pendingApprovals(threadID).isEmpty)
        let dispatch = ComposerDispatch.resolve(
            running: runner.isRunning(threadID), canSteer: runner.canSteer(threadID), alternate: request.delivery == .alternate,
            behavior: behavior)
        declinePendingRequests(threadID)
        switch dispatch {
        case .steer:
            let delivery = await runner.steer(threadID: threadID, text: text, imagePaths: imagePaths)
            return Self.name(delivery)
        case .interrupt:
            return Self.name(await runner.interrupt(threadID: threadID, text: text, imagePaths: imagePaths))
        case .queue where ComposerDispatch.meansToSteer(alternate: request.delivery == .alternate, behavior: behavior):
            return Self.name(await runner.steer(threadID: threadID, text: text, imagePaths: imagePaths))
        case .send, .queue:
            let queues = runner.isRunning(threadID)
            await runner.send(threadID: threadID, text: text, imagePaths: imagePaths)
            return queues ? "queued" : "sent"
        }
    }

    private static func name(_ delivery: ThreadRunner.FollowUpDelivery?) -> String {
        switch delivery {
        case .steered?: "steered"
        case .queued?: "queued"
        case .interrupting?: "interrupting"
        case .sent?, nil: "sent"
        }
    }

    private func declinePendingRequests(_ threadID: UUID) {
        for item in runner.pendingApprovals(threadID) {
            let options = item.approval?.options ?? []
            guard let decline = options.first(where: { $0.kind == .deny }) ?? options.first(where: { $0.kind == .cancel })
            else { continue }
            runner.respond(threadID: threadID, itemID: item.id, optionID: decline.id)
        }
        for item in runner.pendingQuestions(threadID) {
            runner.dismissQuestion(threadID: threadID, itemID: item.id)
        }
    }

    func steerQueued(_ threadID: UUID, messageID: UUID) async throws -> String {
        _ = try requireThread(threadID)
        return Self.name(await runner.steerQueued(threadID: threadID, id: messageID))
    }

    func removeQueued(_ threadID: UUID, messageID: UUID) throws {
        _ = try requireThread(threadID)
        _ = runner.removeQueued(threadID: threadID, id: messageID)
    }

    func stop(_ threadID: UUID) throws {
        _ = try requireThread(threadID)
        runner.stop(threadID: threadID)
    }

    private func waitingItem(_ itemID: UUID, in threadID: UUID, kind: TranscriptItem.Kind) throws -> TranscriptItem {
        _ = try requireThread(threadID)
        guard let item = store.item(itemID, in: threadID), item.kind == kind else {
            throw RemoteError(.notFound, String(localized: "That request no longer exists."))
        }
        guard item.status == .waiting else {
            throw RemoteError(.notAllowed, String(localized: "That request was already answered."))
        }
        return item
    }

    func respond(_ threadID: UUID, itemID: UUID, optionID: String, text: String?) throws {
        let item = try waitingItem(itemID, in: threadID, kind: .approval)
        guard item.approval?.options.contains(where: { $0.id == optionID }) == true else {
            throw RemoteError(.badRequest, String(localized: "That choice isn’t offered."))
        }
        runner.respond(threadID: threadID, itemID: itemID, optionID: optionID, text: text)
    }

    func answer(_ threadID: UUID, itemID: UUID, answers: [String: [String]]) throws {
        _ = try waitingItem(itemID, in: threadID, kind: .question)
        runner.answer(threadID: threadID, itemID: itemID, answers: answers)
    }

    func dismissQuestion(_ threadID: UUID, itemID: UUID) throws {
        _ = try waitingItem(itemID, in: threadID, kind: .question)
        runner.dismissQuestion(threadID: threadID, itemID: itemID)
    }

    /// Changes a thread's agent, model, effort, speed, access or mode, as the composer's footer does.
    func updateSettings(_ request: RemoteThreadSettings) throws {
        let summary = try requireThread(request.threadID)
        var selection = summary.selection
        if request.provider != nil || request.modelID != nil || request.accountID != nil {
            let provider = try request.provider.map { raw -> ProviderKind in
                guard let kind = ProviderKind(rawValue: raw) else {
                    throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that agent."))
                }
                return kind
            } ?? selection.provider
            let accountID = request.accountID ?? (provider == selection.provider ? selection.accountID : nil)
            let modelID: String
            if let requested = request.modelID, !requested.isEmpty {
                modelID = requested
            } else if provider == selection.provider {
                modelID = selection.modelID
            } else {
                guard let first = registry.pickerModels(for: provider, account: accountID, current: nil).first else {
                    throw RemoteError(.notAllowed, String(localized: "\(provider.displayName) has no models to pick from."))
                }
                modelID = first.modelID
            }
            selection = ModelSelection(provider: provider, modelID: modelID, accountID: accountID)
        }
        let model = registry.model(for: selection)
        if let effort = request.effort {
            guard model == nil || model?.efforts.contains(effort) == true else {
                throw RemoteError(.badRequest, String(localized: "The model doesn’t offer that effort."))
            }
            selection.effort = effort
        }
        if let speed = request.speed {
            if speed == RemoteThreadSettings.standardSpeed {
                selection.speed = nil
            } else {
                guard model?.speed(speed) != nil else {
                    throw RemoteError(.badRequest, String(localized: "The model doesn’t offer that speed."))
                }
                selection.speed = speed
            }
        }
        let access = try request.accessMode.map { raw -> AccessMode in
            guard let mode = AccessMode(rawValue: raw) else { throw RemoteError(.badRequest, "Unknown access mode.") }
            return mode
        }
        let interaction = try request.interactionMode.map { raw -> InteractionMode in
            guard let mode = InteractionMode(rawValue: raw) else { throw RemoteError(.badRequest, "Unknown mode.") }
            return mode
        }
        // Resolve on a copy after validating the whole request, so a rejected request cannot alter its history.
        guard var next = store.thread(request.threadID) else { return }
        if request.provider != nil || request.modelID != nil || request.accountID != nil || request.effort != nil || request.speed != nil {
            next.selectModel(
                selection, option: model, rememberingEffort: request.effort != nil, rememberingSpeed: request.speed != nil)
        }
        if let access { next.accessMode = access }
        if let interaction { next.interactionMode = interaction }
        guard next.selection != summary.selection || next.modelPreferences != store.thread(request.threadID)?.modelPreferences
            || next.accessMode != summary.accessMode || next.interactionMode != summary.interactionMode
        else { return }
        store.updateThread(request.threadID) { thread in
            thread.selection = next.selection
            thread.modelPreferences = next.modelPreferences
            thread.accessMode = next.accessMode
            thread.interactionMode = next.interactionMode
        }
    }

    /// A new thread in the project, or a chat for nil, reusing an untouched one there as the Mac's New Thread does.
    /// Unlike the Mac's command, it doesn't open the thread in the Mac's window.
    func newThread(in projectID: UUID?) throws -> UUID {
        let project: Project
        if let projectID {
            guard let found = store.project(projectID) else {
                throw RemoteError(.notFound, String(localized: "That project no longer exists."))
            }
            project = found
        } else {
            project = store.ensureChatsProject()
        }
        let defaults = store.newThreadDefaults(in: project.id)
        let selection = registry.usableSelection(preferring: defaults.selection)
        if let empty = store.threads(in: project.id).first(where: { thread in
            thread.itemCount == 0 && !thread.hasDraft && !thread.isArchived && !services.isSettled(thread)
                && (thread.snoozedUntil ?? .distantPast) <= Date() && thread.worktreePath == nil
                && thread.selection == selection && thread.accessMode == defaults.accessMode
                && thread.interactionMode == defaults.interactionMode
        }) {
            return empty.id
        }
        return store.createThread(in: project.id, selection: selection).id
    }

    // MARK: Bots

    /// A conversation with the bot, reusing an untouched one waiting there, as the Mac's New Conversation does.
    func newBotConversation(_ botID: UUID) throws -> UUID {
        let bot = try requireBot(botID)
        if let empty = store.conversations(of: botID).first(where: { $0.itemCount == 0 && !$0.hasDraft }) { return empty.id }
        guard let thread = store.startConversation(with: botID, selection: registry.usableSelection(preferring: bot.selection))
        else { throw RemoteError(.failed, String(localized: "Couldn’t start a conversation with \(bot.displayName).")) }
        return thread.id
    }

    /// Creates a bot (a draft without an id) or edits one, as the Mac's bot editor does. Everything is checked before
    /// anything changes, so a rejected draft leaves the bot as it was.
    func saveBot(_ draft: RemoteBotDraft) throws -> UUID {
        guard let shape = BotAvatar.Shape(rawValue: draft.avatar.character), let tint = BotAvatar.Tint(rawValue: draft.avatar.tint)
        else { throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that character or color.")) }
        let existing = try draft.id.map(requireBot)
        let access = try draft.accessMode.map { raw -> AccessMode in
            guard let mode = AccessMode(rawValue: raw) else { throw RemoteError(.badRequest, "Unknown access mode.") }
            return mode
        }
        let interaction = try draft.interactionMode.map { raw -> InteractionMode in
            guard let mode = InteractionMode(rawValue: raw) else { throw RemoteError(.badRequest, "Unknown mode.") }
            return mode
        }
        var selection = existing?.selection ?? registry.usableSelection(preferring: store.settings.defaultSelection)
        if draft.provider != nil || draft.modelID != nil {
            let provider = try draft.provider.map { raw -> ProviderKind in
                guard let kind = ProviderKind(rawValue: raw) else {
                    throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that agent."))
                }
                return kind
            } ?? selection.provider
            let modelID: String
            if let requested = draft.modelID, !requested.isEmpty {
                modelID = requested
            } else if provider == selection.provider {
                modelID = selection.modelID
            } else {
                guard let first = registry.pickerModels(for: provider, account: nil, current: nil).first else {
                    throw RemoteError(.notAllowed, String(localized: "\(provider.displayName) has no models to pick from."))
                }
                modelID = first.modelID
            }
            selection = ModelSelection(provider: provider, modelID: modelID, accountID: provider == selection.provider ? selection.accountID : nil)
        }
        if let effort = draft.effort {
            let model = registry.model(for: selection)
            guard model == nil || model?.efforts.contains(effort) == true else {
                throw RemoteError(.badRequest, String(localized: "The model doesn’t offer that effort."))
            }
            selection.effort = effort
        }
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? shape.defaultName : String(trimmed.prefix(80))
        let persona = String(draft.persona.prefix(20_000))
        guard let original = existing else {
            let bot = store.addBot(
                Bot(
                    name: name, avatar: BotAvatar(shape: shape, tint: tint), persona: persona, selection: selection,
                    accessMode: access ?? .approval, interactionMode: interaction ?? .build))
            return bot.id
        }
        var edited = original
        edited.name = name
        edited.avatar = BotAvatar(shape: shape, tint: tint)
        edited.persona = persona
        edited.selection = selection
        if let access { edited.accessMode = access }
        if let interaction { edited.interactionMode = interaction }
        guard edited != original else { return original.id }
        store.updateBot(original.id) { $0 = edited }
        // As the Mac's editor: new instructions reach the agent at its next message, and an untouched conversation
        // starts with the new agent, model and modes.
        let conversations = store.conversations(of: original.id, includeArchived: true)
        if edited.instructions != original.instructions { RelocatedSessions.end(threads: conversations.map(\.id)) }
        if edited.selection != original.selection || edited.accessMode != original.accessMode
            || edited.interactionMode != original.interactionMode
        {
            for thread in conversations where thread.itemCount == 0 && !runner.isRunning(thread.id) {
                store.updateThread(thread.id) { thread in
                    thread.selection = edited.selection
                    thread.accessMode = edited.accessMode
                    thread.interactionMode = edited.interactionMode
                }
            }
        }
        return original.id
    }

    /// Deletes a bot. Its conversations stop and stay as chats, or are deleted with it when asked, as on the Mac.
    func deleteBot(_ botID: UUID, deletingConversations: Bool) throws {
        _ = try requireBot(botID)
        let conversations = store.conversations(of: botID, includeArchived: true).map(\.id)
        for id in conversations { runner.shutdown(threadID: id) }
        if deletingConversations, !conversations.isEmpty { try services.delete(conversations) }
        store.deleteBot(botID, deletingConversations: false)
    }

    private func requireBot(_ id: UUID) throws -> Bot {
        guard let bot = store.bot(id) else { throw RemoteError(.notFound, String(localized: "That bot no longer exists.")) }
        return bot
    }

    func perform(_ action: RemoteThreadAction, on threadID: UUID) throws {
        let thread = try requireThread(threadID)
        switch action {
        case .rename(let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw RemoteError(.badRequest, String(localized: "A thread needs a name.")) }
            if trimmed != thread.title { store.updateThread(threadID) { $0.title = trimmed } }
        case .pin(let pinned):
            if thread.isPinned != pinned { store.updateThread(threadID) { $0.isPinned = pinned } }
        case .archive(let archived):
            // As on the Mac, a running thread is stopped before it can be archived.
            if archived, runner.isRunning(threadID) {
                throw RemoteError(.notAllowed, String(localized: "Stop the thread before archiving it."))
            }
            services.archive([threadID], archived)
        case .snooze(let date):
            if let date, date <= Date() { throw RemoteError(.badRequest, String(localized: "Pick a time in the future.")) }
            services.snooze(threadID, date)
        case .settle(let settled):
            services.settle([threadID], settled)
        case .markUnread:
            services.markUnread(threadID)
        case .move(let projectID):
            try move(threadID, to: projectID)
        case .delete:
            try services.delete([threadID])
        }
    }

    /// Moves a thread into another project as the Mac's sidebar does (undoably there). A thread in its own worktree, or
    /// one still running, stays put.
    private func move(_ threadID: UUID, to projectID: UUID) throws {
        let thread = try requireThread(threadID)
        guard thread.projectID != projectID else { return }
        guard store.project(projectID) != nil else {
            throw RemoteError(.notFound, String(localized: "That project no longer exists."))
        }
        if let blocker = services.moveBlocker(threadID) { throw RemoteError(.notAllowed, blocker) }
        guard store.canMoveThread(threadID, to: projectID) else {
            throw RemoteError(.notAllowed, String(localized: "This thread can’t move there."))
        }
        services.move(threadID, projectID)
    }

    func hasThread(_ threadID: UUID) -> Bool { store.summary(threadID) != nil }

    /// Expands or collapses a project in the sidebar, as its disclosure triangle does.
    func setProjectExpanded(_ projectID: UUID, expanded: Bool) throws {
        guard let project = store.project(projectID), !project.isChats else {
            throw RemoteError(.notFound, String(localized: "That project no longer exists."))
        }
        guard project.isExpanded != expanded else { return }
        store.updateProject(projectID) { $0.isExpanded = expanded }
    }

    func markSeen(_ threadID: UUID) throws {
        _ = try requireThread(threadID)
        services.markSeen(threadID)
    }

    func runScript(_ threadID: UUID, scriptID: UUID) throws {
        let thread = try requireThread(threadID)
        guard let script = store.project(thread.projectID)?.scripts.first(where: { $0.id == scriptID }) else {
            throw RemoteError(.notFound, String(localized: "That script no longer exists."))
        }
        services.runScript(script, threadID)
    }

    func diff(_ threadID: UUID, turnID: UUID?) async throws -> RemoteDiff {
        _ = try requireThread(threadID)
        return try await services.diff(threadID, turnID)
    }

    func usageLimits() -> [RemoteUsage] {
        var result: [RemoteUsage] = []
        for kind in registry.orderedKinds where store.settings.settings(for: kind).isEnabled {
            let accounts = registry.accounts(for: kind)
            for account in accounts {
                guard let limits = runner.usageLimits(for: kind, account: account.id), !limits.windows.isEmpty else { continue }
                result.append(
                    RemoteUsage(
                        provider: kind.rawValue, providerName: kind.displayName, accountID: account.id,
                        accountName: accounts.count > 1 ? account.name : nil,
                        windows: limits.windows.map {
                            RemoteUsage.Window(id: $0.id, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                        }, checkedAt: limits.checkedAt))
            }
        }
        return result
    }

    // MARK: Diffs

    static func liveDiff(threadID: UUID, turnID: UUID?) async throws -> RemoteDiff {
        if let turnID {
            guard let patch = await CheckpointService.shared.turnDiff(threadID: threadID, userItemID: turnID) else {
                throw RemoteError(.notFound, String(localized: "This turn has no checkpoint to compare with."))
            }
            return RemoteDiffParsing.split(patch, title: String(localized: "Turn changes"))
        }
        guard let cwd = AppStore.shared.workingDirectory(for: threadID) else {
            throw RemoteError(.notFound, String(localized: "The thread’s folder is missing."))
        }
        guard await GitService.shared.isRepository(cwd) else {
            throw RemoteError(.notAllowed, String(localized: "The thread’s folder isn’t a git repository."))
        }
        let diff: GitDiff
        do {
            diff = try await GitService.shared.workingTreeDiff(cwd)
        } catch {
            throw RemoteError(.failed, error.localizedDescription)
        }
        return remoteDiff(diff, title: String(localized: "Uncommitted changes"))
    }

    nonisolated static func remoteDiff(_ diff: GitDiff, title: String, maxPatchBytes: Int = 2_000_000) -> RemoteDiff {
        var bytes = 0
        var truncated = diff.isTruncated
        let files = diff.files.map { file -> RemoteDiff.File in
            var patch = file.hunks.map { hunk in
                ([hunk.header] + hunk.lines.map { line in
                    switch line.kind {
                    case .addition: "+" + line.text
                    case .deletion: "-" + line.text
                    case .context: " " + line.text
                    case .noNewline: "\\ " + line.text
                    }
                }).joined(separator: "\n")
            }.joined(separator: "\n")
            if bytes + patch.utf8.count > maxPatchBytes {
                patch = ""
                truncated = true
            }
            bytes += patch.utf8.count
            return RemoteDiff.File(
                path: file.path, oldPath: file.oldPath, status: file.status.rawValue, additions: file.additions,
                deletions: file.deletions, isBinary: file.isBinary, patch: patch)
        }
        return RemoteDiff(title: title, files: files, isTruncated: truncated)
    }
}

/// Ends an adapter observation when released.
@MainActor
final class ObservationHandle {
    private let cancel: () -> Void

    init(cancel: @escaping () -> Void) {
        self.cancel = cancel
    }

    isolated deinit {
        cancel()
    }
}
