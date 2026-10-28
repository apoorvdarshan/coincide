import Foundation

/// Schedules live beside the application data. A failed read never permits silently replacing the original file.
@MainActor public final class ScheduledTaskStore {
    private struct File: Codable { var version = 1; var tasks: [ScheduledTask] }
    public private(set) var tasks: [ScheduledTask] = []
    public private(set) var loadError: String?
    public var onChange: (() -> Void)?
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("scheduled-tasks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(File.self, from: Data(contentsOf: url))
            guard file.version == 1, file.tasks.allSatisfy(\.isValid), Set(file.tasks.map(\.id)).count == file.tasks.count else {
                throw ScheduleError.invalidTask
            }
            tasks = file.tasks
        } catch { loadError = error.localizedDescription }
    }

    public func task(_ id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    public func save(_ task: ScheduledTask) throws {
        guard task.isValid else { throw ScheduleError.invalidTask }
        var values = tasks
        if let index = values.firstIndex(where: { $0.id == task.id }) { values[index] = task }
        else { values.append(task) }
        try replace(values)
    }

    public func delete(_ id: UUID) throws { try replace(tasks.filter { $0.id != id }) }

    private func replace(_ values: [ScheduledTask]) throws {
        if let loadError { throw ScheduleError.storage(loadError) }
        do {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(tasks: values)).write(to: url, options: .atomic)
        } catch { throw ScheduleError.storage(error.localizedDescription) }
        tasks = values
        onChange?()
    }
}
