import CoincideKit
import CoincideRemoteKit
import Foundation

/// The sidebar's options and a project's settings from Coincide Remote, through the calls the Mac's sidebar menus
/// make: sorting and threads per project, "Project Defaults…" and "Remove from Coincide…".
extension RemoteStoreAdapter {
    // MARK: Sidebar

    static func sidebarOptions(_ layout: Services.Layout) -> RemoteSidebarOptions {
        RemoteSidebarOptions(
            projectSort: layout.projectSort.rawValue, threadSort: layout.threadSort.rawValue, chatSort: layout.chatSort.rawValue,
            botSort: layout.botSort.rawValue, threadsPerProject: layout.threadsPerProject)
    }

    /// Sorts the Mac's lists and cuts its projects as the phone chose. A sort this Mac doesn't know is refused; the
    /// rest of the Mac's layout (sections, pins) stays.
    func setSidebarOptions(_ options: RemoteSidebarOptions) throws {
        guard let projectSort = ProjectSort(rawValue: options.projectSort), let threadSort = ThreadSort(rawValue: options.threadSort),
            let chatSort = ThreadSort(rawValue: options.chatSort), let botSort = BotSort(rawValue: options.botSort)
        else { throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that sort order.")) }
        guard (options.threadsPerProject ?? 0) >= 0 else {
            throw RemoteError(.badRequest, String(localized: "Choose how many threads a project shows."))
        }
        var layout = services.layout()
        layout.projectSort = projectSort
        layout.threadSort = threadSort
        layout.chatSort = chatSort
        layout.botSort = botSort
        layout.threadsPerProject = options.threadsPerProject
        services.updateLayout(layout)
        // The order lives outside the store, so no store change tells the phones.
        emitWorkspaceChange()
    }

    // MARK: Projects

    /// A project the phone may change: one of the user's folders, not Chats or the bots' home.
    private func requireFolderProject(_ projectID: UUID) throws -> Project {
        guard let project = store.project(projectID) else {
            throw RemoteError(.notFound, String(localized: "That project no longer exists."))
        }
        guard !project.isChats, !project.isBots else {
            throw RemoteError(.notAllowed, String(localized: "Only projects with a folder have this."))
        }
        return project
    }

    /// What the project's new threads start with: its own defaults, or the global ones it follows.
    func projectDefaults(_ projectID: UUID) throws -> RemoteProjectDefaults {
        let project = try requireFolderProject(projectID)
        let defaults = store.newThreadDefaults(in: project.id)
        return RemoteProjectDefaults(
            projectID: project.id, usesGlobalDefaults: project.threadDefaults == nil, provider: defaults.selection.provider.rawValue,
            modelID: defaults.selection.modelID, effort: defaults.selection.effort, accessMode: defaults.accessMode.rawValue,
            interactionMode: defaults.interactionMode.rawValue)
    }

    /// Saves the project's defaults as the Mac's Project Defaults sheet does; existing threads keep their settings.
    func saveProjectDefaults(_ request: RemoteProjectDefaults) throws -> RemoteProjectDefaults {
        let project = try requireFolderProject(request.projectID)
        guard !request.usesGlobalDefaults else {
            store.updateProject(project.id) { $0.threadDefaults = nil }
            return try projectDefaults(project.id)
        }
        guard let provider = ProviderKind(rawValue: request.provider) else {
            throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that agent."))
        }
        guard let access = AccessMode(rawValue: request.accessMode), let interaction = InteractionMode(rawValue: request.interactionMode)
        else { throw RemoteError(.badRequest, String(localized: "This Mac doesn’t know that mode.")) }
        let current = store.newThreadDefaults(in: project.id).selection
        var selection = ModelSelection(
            provider: provider, modelID: request.modelID.isEmpty ? current.modelID : request.modelID,
            accountID: provider == current.provider ? current.accountID : nil)
        let model = registry.model(for: selection)
        if let effort = request.effort {
            guard model == nil || model?.efforts.contains(effort) == true else {
                throw RemoteError(.badRequest, String(localized: "The model doesn’t offer that effort."))
            }
            selection.effort = effort
        }
        if provider == current.provider { selection.speed = model?.speed(current.speed)?.id }
        store.updateProject(project.id) {
            $0.threadDefaults = ProjectThreadDefaults(selection: selection, accessMode: access, interactionMode: interaction)
        }
        return try projectDefaults(project.id)
    }

    /// Removes the project from Coincide as "Remove from Coincide…" does: its threads (archived ones too) stop and are
    /// deleted; its folder and files stay. The phone asks first.
    func removeProject(_ projectID: UUID) throws {
        let project = try requireFolderProject(projectID)
        for thread in store.threads(in: project.id, includeArchived: true) { runner.shutdown(threadID: thread.id) }
        store.removeProject(project.id)
    }
}
