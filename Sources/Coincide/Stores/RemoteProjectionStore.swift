import CoincideCore
import CryptoKit
import Foundation
import Observation

/// A projection is presentation data. Complete native configuration and request
/// documents are hydrated separately, never manufactured from preview fields.
struct RemoteProjectionControl {
    let binding: RemoteProjectionBinding
    let detail: RemoteThreadDetail
    let configuration: ProviderConfiguration
    let draft: String
    let attachments: [ChatAttachment]
    let requests: [RuntimeRequest]
    var target: RemoteWorkspaceTarget {
        .init(environmentID: binding.environmentID, projectID: detail.summary.projectID,
              threadID: detail.summary.id, configuration: configuration)
    }
}

@MainActor @Observable
final class RemoteProjectionStore {
    private(set) var catalogBinding: RemoteProjectionBinding?
    private(set) var browseBinding: RemoteProjectionBinding?
    private(set) var control: RemoteProjectionControl?
    private(set) var projects: [RemoteProjectSummary] = []
    private(set) var threads: [RemoteThreadSummary] = []
    private(set) var messages: [RemoteMessageSummary] = [] // newest first, including removed audit rows
    private(set) var runs: [RemoteRunSummary] = []
    private(set) var operations: [RemoteOperationSummary] = []
    private(set) var currentOperations: [RemoteOperationSummary] = []
    private(set) var projectCount = 0
    private(set) var threadCount = 0
    private(set) var messageCount = 0
    private(set) var runCount = 0
    private(set) var operationCount = 0
    private(set) var projectsComplete = false
    private(set) var threadsComplete = false
    private(set) var messagesComplete = false
    private(set) var runsComplete = false
    private(set) var operationsComplete = false
    private(set) var connected = false
    private var loads: Set<UUID> = []
    var isLoading: Bool { !loads.isEmpty }
    private(set) var hasNewerContent = false
    private(set) var followsLatest = true
    private(set) var errorMessage: String?
    private(set) var selectedThreadID: UUID?
    @ObservationIgnored private var client: RemoteEnvironmentClient?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var controlRead = UUID()
    @ObservationIgnored private var catalogRead = UUID()
    @ObservationIgnored private var projectCursor: UUID?
    @ObservationIgnored private var threadCursor: UUID?
    @ObservationIgnored private var messageCursor: UUID?
    @ObservationIgnored private var runCursor: UUID?
    @ObservationIgnored private var operationCursor: UUID?
    @ObservationIgnored private var projectOffset = 0
    @ObservationIgnored private var threadOffset = 0
    @ObservationIgnored private var messageOffset = 0
    @ObservationIgnored private var runOffset = 0
    @ObservationIgnored private var operationOffset = 0
    @ObservationIgnored private var desiredSequence: Int64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var changed: (@MainActor () -> Void)?
    static let retainedRows = 512
    var controlIsCurrent: Bool { connected && control?.detail.summary.id == selectedThreadID }
    var controlHasNewerState: Bool { (control?.binding.sequence ?? -1) < desiredSequence }
    var visibleMessages: [RemoteMessageSummary] { messages.reversed().filter { $0.removedByHistoryOperationID == nil } }
    var catalogOutdated: Bool { (catalogBinding?.sequence ?? 0) < desiredSequence }
    var messageWindowStart: Int { max(0, messageOffset - messages.count) }
    var projectWindowStart: Int { max(0, projectOffset - projects.count) }
    var threadWindowStart: Int { max(0, threadOffset - threads.count) }
    var runWindowStart: Int { max(0, runOffset - runs.count) }
    var operationWindowStart: Int { max(0, operationOffset - operations.count) }
    var canLoadProjects: Bool { projectCursor != nil && connected && !isLoading }
    var canLoadThreads: Bool { threadCursor != nil && connected && !isLoading }
    var canLoadEarlier: Bool { messageCursor != nil && connected && !isLoading }
    var canLoadRuns: Bool { runCursor != nil && connected && !isLoading }
    var canLoadOperations: Bool { operationCursor != nil && connected && !isLoading }

    func connect(client: RemoteEnvironmentClient, binding: RemoteProjectionBinding, changed: @escaping @MainActor () -> Void) async throws {
        disconnect(); generation = UUID(); self.client = client; connected = true; self.changed = changed
        let owner = generation, loading = beginLoad()
        defer { finishLoad(loading, owner: owner) }
        catalogBinding = binding; desiredSequence = binding.sequence
        projects = []; threads = []; projectCount = 0; threadCount = 0; projectCursor = nil; threadCursor = nil
        control = nil; selectedThreadID = nil; browseBinding = nil; messages = []; runs = []; operations = []; currentOperations = []
        let token = UUID(); catalogRead = token
        _ = try await refreshCatalog(binding: binding, owner: owner, token: token)
    }
    func disconnect() {
        generation = UUID(); controlRead = UUID(); catalogRead = UUID(); connected = false; client = nil
        refreshTask?.cancel(); refreshTask = nil; loads = []
        // Cached pages are readable after disconnect. Their leases cannot act.
    }
    func beginSelection(_ id: UUID?) {
        guard selectedThreadID != id else { return }
        if let old = control?.binding, let client { Task { _ = try? await client.projectionRelease(.init(binding: old)) } }
        selectedThreadID = id; controlRead = UUID(); control = nil; currentOperations = []
    }
    func select(_ id: UUID?) async {
        guard selectedThreadID != id || control == nil else { return }
        selectedThreadID = id; let token = UUID(); controlRead = token; control = nil
        messages = []; runs = []; operations = []; currentOperations = []
        messagesComplete = false; runsComplete = false; operationsComplete = false
        messageCursor = nil; runCursor = nil; operationCursor = nil
        let old = browseBinding; browseBinding = nil
        if let old, let client { _ = try? await client.projectionRelease(.init(binding: old)) }
        guard controlRead == token, selectedThreadID == id, connected else { return }
        guard let id else { changed?(); return }
        followsLatest = true
        await refreshSelected(threadID: id, repin: true)
    }
    func invalidate(_ value: RemoteProjectionInvalidation) {
        guard connected, catalogBinding?.environmentID == value.environmentID else { return }
        if catalogBinding?.hostID != value.hostID { errorMessage = "The remote host restarted. Reconnect to open fresh views."; disconnect(); changed?(); return }
        desiredSequence = max(desiredSequence, value.sequence)
        hasNewerContent = browseBinding.map { $0.sequence < desiredSequence } ?? false
        guard refreshTask == nil else { return }
        let owner = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == owner { self.refreshTask = nil } }
            while self.connected, self.generation == owner {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard self.connected, self.generation == owner else { return }
                let desired = self.desiredSequence
                if let id = self.selectedThreadID { await self.refreshSelected(threadID: id, repin: self.followsLatest) }
                guard self.desiredSequence > desired else { break }
            }
        }
    }
    func refreshLatest() async {
        guard let client, connected else { return }
        // Ownership starts before open: a late older open cannot replace a
        // newer catalog, even though its immutable lease remains readable.
        let owner = generation, token = UUID(), loading = beginLoad(); catalogRead = token
        defer { finishLoad(loading, owner: owner) }
        var unused: RemoteProjectionBinding?
        do {
            let binding = try await client.openProjection(scope: .catalog, minimumSequence: desiredSequence)
            unused = binding
            guard generation == owner, catalogRead == token, connected, !Task.isCancelled else { throw CancellationError() }
            let replaced = try await refreshCatalog(binding: binding, owner: owner, token: token)
            unused = nil
            if let replaced { _ = try? await client.projectionRelease(.init(binding: replaced)) }
            guard generation == owner, catalogRead == token, connected, !Task.isCancelled else { return }
            if let id = selectedThreadID { await refreshSelected(threadID: id, repin: followsLatest) }
        } catch is CancellationError { }
        catch { if generation == owner, catalogRead == token { errorMessage = error.localizedDescription } }
        if let unused { _ = try? await client.projectionRelease(.init(binding: unused)) }
    }
    func refreshControl() async { if let id = selectedThreadID { await refreshSelected(threadID: id, repin: followsLatest) } }
    func followLatest() async { followsLatest = true; if let id = selectedThreadID { await refreshSelected(threadID: id, repin: true) } }
    func pauseFollowing() { followsLatest = false }

    private func refreshCatalog(binding: RemoteProjectionBinding, owner: UUID, token: UUID) async throws -> RemoteProjectionBinding? {
        guard let client, generation == owner, catalogRead == token else { throw CancellationError() }
        let p = try await client.projectionCatalog(.init(binding: binding, query: .projects))
        let t = try await client.projectionCatalog(.init(binding: binding, query: .threads(projectID: nil, includeArchived: false)))
        guard generation == owner, catalogRead == token, connected, !Task.isCancelled else { throw CancellationError() }
        guard case .projects(let projects) = p, case .threads(let threads) = t else { throw RemoteProjectionFailure(.invalidRequest) }
        try Self.validate(projects, binding: binding, offset: 0); try Self.validate(threads, binding: binding, offset: 0)
        let replaced = catalogBinding
        catalogBinding = binding
        self.projects = projects.items; projectCount = projects.totalCount; projectsComplete = projects.complete
        projectCursor = projects.nextCursor; projectOffset = projects.items.count
        self.threads = threads.items; threadCount = threads.totalCount; threadsComplete = threads.complete
        threadCursor = threads.nextCursor; threadOffset = threads.items.count
        changed?()
        return replaced?.viewID == binding.viewID ? nil : replaced
    }
    private func refreshSelected(threadID: UUID, repin: Bool) async {
        guard let client, connected else { return }
        let owner = generation, token = UUID(); controlRead = token
        let loading = beginLoad()
        defer { finishLoad(loading, owner: owner) }
        var temporary: [RemoteProjectionBinding] = []
        do {
            let binding = try await client.openProjection(scope: .control(threadID), minimumSequence: desiredSequence)
            temporary.append(binding)
            let result = try await client.projectionThread(.init(binding: binding, threadID: threadID))
            guard result.binding == binding, result.thread.summary.id == threadID else { throw RemoteProjectionFailure(.invalidRequest) }
            let detail = result.thread
            async let configData = client.projectionDocument(detail.configuration, binding: binding)
            async let attachmentData = client.projectionDocument(detail.draftAttachments, binding: binding)
            async let requestData = client.projectionDocument(detail.runtimeRequests, binding: binding)
            let configuration = try JSONDecoder().decode(ProviderConfiguration.self, from: await configData)
            let attachments = try JSONDecoder().decode([ChatAttachment].self, from: await attachmentData)
            let requests = try JSONDecoder().decode([RuntimeRequest].self, from: await requestData)
            let draft: String
            if detail.draft.complete { draft = detail.draft.preview }
            else if let reference = detail.draft.content, reference.kind == .draft,
                    let value = String(data: try await client.projectionDocument(reference, binding: binding), encoding: .utf8) { draft = value }
            else { throw RemoteProjectionFailure(.invalidRequest) }
            guard detail.configuration.kind == .configuration, detail.draftAttachments.kind == .attachmentReferences,
                  detail.runtimeRequests.kind == .runtimeRequests, requests.count == detail.requestCount,
                  configuration.workspacePath.utf8.elementsEqual(detail.summary.workspacePath.utf8),
                  configuration.provider == detail.summary.provider, configuration.permission == detail.summary.permission,
                  !detail.summary.model.complete || configuration.model.utf8.elementsEqual(detail.summary.model.preview.utf8) else { throw RemoteProjectionFailure(.invalidRequest) }
            var heads: [RemoteOperationSummary] = [], cursor: UUID?, offset = 0
            repeat {
                let page = try await client.projectionOperations(.init(binding: binding, threadID: threadID, cursor: cursor))
                try Self.validate(page, binding: binding, offset: offset)
                heads += page.items; offset += page.items.count; cursor = page.nextCursor
                guard heads.count <= 4_096 else { throw RemoteProjectionFailure(.limitExceeded) }
            } while cursor != nil
            guard generation == owner, controlRead == token, selectedThreadID == threadID, connected, !Task.isCancelled else { throw CancellationError() }
            let oldControl = control?.binding
            control = .init(binding: binding, detail: detail, configuration: configuration, draft: draft, attachments: attachments, requests: requests)
            currentOperations = heads; temporary.removeAll { $0 == binding }
            if let oldControl { _ = try? await client.projectionRelease(.init(binding: oldControl)) }
            changed?()
            if repin {
                let browse = try await client.openProjection(scope: .thread(threadID), minimumSequence: binding.sequence)
                temporary.append(browse)
                let m = try await client.projectionMessages(.init(binding: browse, threadID: threadID))
                let r = try await client.projectionRuns(.init(binding: browse, threadID: threadID))
                let o = try await client.projectionOperations(.init(binding: browse, threadID: threadID))
                try Self.validate(m, binding: browse, offset: 0); try Self.validate(r, binding: browse, offset: 0); try Self.validate(o, binding: browse, offset: 0)
                guard generation == owner, controlRead == token, selectedThreadID == threadID, connected, !Task.isCancelled else { throw CancellationError() }
                let old = browseBinding; browseBinding = browse; temporary.removeAll { $0 == browse }
                messages = m.items; messageCount = m.totalCount; messageOffset = m.items.count; messageCursor = m.nextCursor; messagesComplete = m.complete
                runs = r.items; runCount = r.totalCount; runOffset = r.items.count; runCursor = r.nextCursor; runsComplete = r.complete
                operations = o.items; operationCount = o.totalCount; operationOffset = o.items.count; operationCursor = o.nextCursor; operationsComplete = o.complete
                if let old { _ = try? await client.projectionRelease(.init(binding: old)) }
                hasNewerContent = browse.sequence < desiredSequence
            }
            errorMessage = nil; changed?()
        } catch is CancellationError { }
        catch { if generation == owner, controlRead == token { errorMessage = error.localizedDescription } }
        for binding in temporary { _ = try? await client.projectionRelease(.init(binding: binding)) }
    }
    func loadProjects() async { await pageCatalog(projects: true) }
    func loadThreads() async { await pageCatalog(projects: false) }
    private func pageCatalog(projects isProjects: Bool) async {
        guard connected, !isLoading, let client, let binding = catalogBinding, let cursor = isProjects ? projectCursor : threadCursor else { return }
        let owner = generation, token = catalogRead, loading = beginLoad()
        defer { finishLoad(loading, owner: owner) }
        do {
            let result = try await client.projectionCatalog(.init(binding: binding, query: isProjects ? .projects : .threads(projectID: nil, includeArchived: false), cursor: cursor))
            guard owner == generation, catalogRead == token, binding == catalogBinding, !Task.isCancelled else { return }
            switch result {
            case .projects(let page) where isProjects:
                try Self.validate(page, binding: binding, offset: projectOffset)
                projects = Self.retain(projects + page.items); projectOffset += page.items.count; projectCursor = page.nextCursor; projectsComplete = page.complete
            case .threads(let page) where !isProjects:
                try Self.validate(page, binding: binding, offset: threadOffset)
                threads = Self.retain(threads + page.items); threadOffset += page.items.count; threadCursor = page.nextCursor; threadsComplete = page.complete
            default: throw RemoteProjectionFailure(.invalidRequest)
            }
            changed?()
        } catch { if owner == generation, catalogRead == token, catalogBinding == binding { errorMessage = error.localizedDescription } }
    }
    enum Collection { case messages, runs, operations }
    func loadMore(_ collection: Collection) async {
        guard connected, !isLoading, let client, let binding = browseBinding, let id = selectedThreadID else { return }
        let owner = generation, loading = beginLoad(); followsLatest = false
        defer { finishLoad(loading, owner: owner) }
        do {
            switch collection {
            case .messages:
                guard let cursor = messageCursor else { return }
                let page = try await client.projectionMessages(.init(binding: binding, threadID: id, cursor: cursor))
                guard generation == owner, browseBinding == binding else { return }; try Self.validate(page, binding: binding, offset: messageOffset)
                let combined = messages + page.items
                if combined.count > Self.retainedRows { hasNewerContent = true }
                messages = Self.retain(combined); messageOffset += page.items.count; messageCursor = page.nextCursor; messagesComplete = page.complete
            case .runs:
                guard let cursor = runCursor else { return }
                let page = try await client.projectionRuns(.init(binding: binding, threadID: id, cursor: cursor))
                guard generation == owner, browseBinding == binding else { return }; try Self.validate(page, binding: binding, offset: runOffset)
                runs = Self.retain(runs + page.items); runOffset += page.items.count; runCursor = page.nextCursor; runsComplete = page.complete
            case .operations:
                guard let cursor = operationCursor else { return }
                let page = try await client.projectionOperations(.init(binding: binding, threadID: id, cursor: cursor))
                guard generation == owner, browseBinding == binding else { return }; try Self.validate(page, binding: binding, offset: operationOffset)
                operations = Self.retain(operations + page.items); operationOffset += page.items.count; operationCursor = page.nextCursor; operationsComplete = page.complete
            }
            changed?()
        } catch { if owner == generation, browseBinding == binding { errorMessage = error.localizedDescription } }
    }
    func document(_ reference: RemoteProjectionContentReference, binding: RemoteProjectionBinding) async throws -> Data {
        guard connected, let client else { throw RemoteProjectionFailure(.unavailable) }
        return try await client.projectionDocument(reference, binding: binding)
    }
    func content(_ request: RemoteProjectionContentRequest) async throws -> RemoteProjectionContentResult {
        guard connected, let client else { throw RemoteProjectionFailure(.unavailable) }; return try await client.projectionContent(request)
    }
    private func beginLoad() -> UUID { let id = UUID(); loads.insert(id); return id }
    private func finishLoad(_ id: UUID, owner: UUID) { if generation == owner { loads.remove(id) } }
    private static func retain<T>(_ values: [T]) -> [T] { Array(values.suffix(retainedRows)) }
    static func validate<T>(_ page: RemoteProjectionPage<T>, binding: RemoteProjectionBinding, offset: Int) throws where T: Identifiable {
        guard page.binding == binding, page.offset == offset, page.totalCount >= offset + page.items.count,
              Set(page.items.map(\.id)).count == page.items.count,
              page.complete == (page.nextCursor == nil), page.complete == (offset + page.items.count == page.totalCount),
              page.complete || !page.items.isEmpty else { throw RemoteProjectionFailure(.invalidRequest) }
    }
}
