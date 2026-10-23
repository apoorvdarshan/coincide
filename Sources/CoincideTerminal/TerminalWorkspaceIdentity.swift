import CoincideCore
import Darwin
import Foundation

/// Saved terminal ownership, never a process identity or authority to reconnect.
/// A new shell may start only while the same conversation and physical folders
/// still match this original capture.
public struct TerminalWorkspaceIdentity: Codable, Equatable, Sendable {
    public let threadID: UUID
    public let projectID: UUID
    public let threadCreatedAt: Date
    public let workspacePath: String
    public let workspacePreparationID: UUID?
    public let directory: String
    public let workspaceDevice: UInt64, workspaceInode: UInt64
    public let directoryDevice: UInt64, directoryInode: UInt64

    public static func capture(thread: CodingThread, directory: URL? = nil) throws -> Self {
        let directory = (directory ?? URL(fileURLWithPath: thread.workspacePath)).standardizedFileURL
        let workspace = try node(thread.workspacePath), launch = try node(directory.path)
        return .init(threadID: thread.id, projectID: thread.projectID, threadCreatedAt: thread.createdAt,
            workspacePath: thread.workspacePath, workspacePreparationID: thread.workspacePreparation?.id,
            directory: directory.path, workspaceDevice: workspace.0, workspaceInode: workspace.1,
            directoryDevice: launch.0, directoryInode: launch.1)
    }

    public func matches(thread: CodingThread) -> Bool {
        guard isValid, thread.id == threadID, thread.projectID == projectID, thread.createdAt == threadCreatedAt,
              thread.workspacePath.utf8.elementsEqual(workspacePath.utf8),
              thread.workspacePreparation?.id == workspacePreparationID,
              let workspace = try? Self.node(thread.workspacePath), let launch = try? Self.node(directory) else { return false }
        return workspace.0 == workspaceDevice && workspace.1 == workspaceInode && launch.0 == directoryDevice && launch.1 == directoryInode
    }

    public func matchesDirectory(_ value: String) -> Bool {
        guard value.utf8.elementsEqual(directory.utf8), let node = try? Self.node(value) else { return false }
        return node.0 == directoryDevice && node.1 == directoryInode
    }

    public var isValid: Bool {
        threadCreatedAt.timeIntervalSince1970.isFinite && Self.path(workspacePath) && Self.path(directory) && workspaceInode != 0 && directoryInode != 0
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.projectID == rhs.projectID && lhs.threadCreatedAt == rhs.threadCreatedAt &&
            lhs.workspacePreparationID == rhs.workspacePreparationID && lhs.workspacePath.utf8.elementsEqual(rhs.workspacePath.utf8) &&
            lhs.directory.utf8.elementsEqual(rhs.directory.utf8) && lhs.workspaceDevice == rhs.workspaceDevice &&
            lhs.workspaceInode == rhs.workspaceInode && lhs.directoryDevice == rhs.directoryDevice && lhs.directoryInode == rhs.directoryInode
    }

    private static func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 16_384 }
    private static func node(_ path: String) throws -> (UInt64, UInt64) {
        guard Self.path(path) else { throw CoincideError("This terminal workspace changed. Open a new terminal instead.") }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CoincideError("This terminal workspace changed. Open a new terminal instead.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CoincideError("This terminal workspace changed. Open a new terminal instead.")
        }
        return (UInt64(truncatingIfNeeded: info.st_dev), info.st_ino)
    }
}
