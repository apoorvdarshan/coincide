import Darwin
import Foundation

private struct EditorNodeIdentity: Sendable, Equatable {
    let device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(truncatingIfNeeded: value.st_dev); inode = value.st_ino; size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }
}

/// Only an inspected macOS application and one of its own contained launchers can be handed off.
/// PATH wrappers, shell profiles, helpers with a similar name, and external CLI symlinks are ignored.
public struct ExternalEditorInstallation: Sendable, Equatable {
    public let id: ExternalEditorID
    public let applicationURL: URL
    public let executableURL: URL
    private let applicationIdentity: EditorNodeIdentity
    private let mainIdentity: EditorNodeIdentity
    private let launcherIdentity: EditorNodeIdentity
    private let infoIdentity: EditorNodeIdentity

    public init(id: ExternalEditorID, applicationURL: URL) throws {
        try Task.checkCancellation()
        guard id != .fileManager, applicationURL.isFileURL else { throw Self.invalid() }
        let application = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard ExternalEditorCatalog.acceptsBundleName(application.lastPathComponent, id: id) else { throw Self.invalid() }
        let appNode = try Self.inspect(application, directory: true)
        let infoURL = try Self.contained("Contents/Info.plist", in: application)
        let (data, infoNode) = try Self.readInfo(infoURL)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = plist as? [String: Any], info["CFBundlePackageType"] as? String == "APPL",
              let bundleID = info["CFBundleIdentifier"] as? String,
              ExternalEditorCatalog.bundleIdentifiers(for: id).contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }),
              let mainName = info["CFBundleExecutable"] as? String, !mainName.isEmpty,
              mainName != ".", mainName != "..", !mainName.contains("/"), !mainName.contains("\0") else { throw Self.invalid() }
        let main = try Self.contained("Contents/MacOS/" + mainName, in: application)
        let mainNode = try Self.inspect(main, executable: true)
        var launcher: (URL, EditorNodeIdentity)?
        for relative in ExternalEditorCatalog.definition(id).launchers {
            try Task.checkCancellation()
            if let url = try? Self.contained(relative, in: application), let identity = try? Self.inspect(url, executable: true) {
                launcher = (url, identity); break
            }
        }
        guard let launcher, try Self.inspect(application, directory: true) == appNode else { throw Self.invalid() }
        self.id = id; self.applicationURL = application; executableURL = launcher.0
        applicationIdentity = appNode; mainIdentity = mainNode; launcherIdentity = launcher.1; infoIdentity = infoNode
    }

    public func validate() throws {
        guard try ExternalEditorInstallation(id: id, applicationURL: applicationURL) == self else { throw Self.invalid() }
    }
    private static func invalid() -> ExternalEditorError {
        .init(.invalidInstallation, "This editor installation is unavailable or changed. Refresh the installed editors and try again.")
    }
    private static func contained(_ relative: String, in root: URL) throws -> URL {
        let result = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard result.path.hasPrefix(root.path + "/") else { throw invalid() }
        return result
    }
    private static func inspect(_ url: URL, directory: Bool = false, executable: Bool = false) throws -> EditorNodeIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              !executable || (value.st_mode & 0o111 != 0 && access(url.path, X_OK) == 0) else { throw invalid() }
        return .init(value)
    }
    private static func readInfo(_ url: URL) throws -> (Data, EditorNodeIdentity) {
        let file = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw invalid() }
        defer { Darwin.close(file) }
        var before = stat()
        guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 1_048_576 else { throw invalid() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= 1_048_576 {
            try Task.checkCancellation()
            let count = Darwin.read(file, &buffer, min(buffer.count, 1_048_577 - data.count))
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw invalid() }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard data.count <= 1_048_576, fstat(file, &after) == 0, EditorNodeIdentity(before) == EditorNodeIdentity(after) else { throw invalid() }
        return (data, .init(after))
    }
}

extension ExternalEditorCatalog {
    /// Nonrecursive, bounded application discovery. Registered URLs come from Launch Services;
    /// directory roots cover ordinary installations and versioned JetBrains Toolbox bundles.
    public static func discover(applicationDirectories: [URL], registeredApplications: [URL] = []) throws -> [ExternalEditorInstallation] {
        var candidates = Array(registeredApplications.prefix(256)), seen = Set<String>()
        for root in applicationDirectories.prefix(8) where root.isFileURL {
            try Task.checkCancellation()
            guard let stream = opendir(root.path) else { continue }
            defer { closedir(stream) }
            var count = 0
            while count < 4_096, let entry = readdir(stream) {
                try Task.checkCancellation(); count += 1
                let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
                }
                guard let name, ExternalEditorID.allCases.contains(where: { acceptsBundleName(name, id: $0) }) else { continue }
                candidates.append(root.appendingPathComponent(name, isDirectory: true))
            }
        }
        var result: [ExternalEditorInstallation] = []
        for id in ExternalEditorID.allCases where id != .fileManager {
            for application in candidates where acceptsBundleName(application.lastPathComponent, id: id) {
                try Task.checkCancellation()
                guard let installation = try? ExternalEditorInstallation(id: id, applicationURL: application),
                      seen.insert(id.rawValue).inserted else { continue }
                result.append(installation); break
            }
        }
        try Task.checkCancellation(); return result
    }
}
