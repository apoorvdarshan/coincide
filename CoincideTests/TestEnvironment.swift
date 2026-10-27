import Foundation

/// The test bundle's principal class (`NSPrincipalClass` in its Info.plist). XCTest creates it as it loads
/// the bundle into the host app, before any test runs, so it can point everything the app keeps on disk
/// (`AppStore.shared`, `UIState.shared` and the files beside them) at a scratch folder through
/// `COINCIDE_DATA_DIR`. Tests then never read or change the user's projects, threads or settings.
///
/// The host app's launch guard (`AppDelegate.isHostingTests`) makes sure nothing touched those stores
/// before this ran.
nonisolated final class TestEnvironment: NSObject {
    /// The scratch folder the shared stores use for this test run.
    static let dataDirectory: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoincideTests", isDirectory: true)
        removeStaleRuns(in: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL
    }()

    /// Set once, before the folder is removed at exit.
    nonisolated(unsafe) private static var directoryToRemove: String?

    override init() {
        super.init()
        Self.install()
    }

    /// Points `COINCIDE_DATA_DIR` at this run's scratch folder unless the run chose one itself.
    static func install() {
        guard directoryToRemove == nil else { return }
        if let chosen = ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"], !chosen.isEmpty {
            directoryToRemove = ""
            return
        }
        let path = dataDirectory.path
        setenv("COINCIDE_DATA_DIR", path, 1)
        directoryToRemove = path
        atexit {
            guard let path = TestEnvironment.directoryToRemove, !path.isEmpty else { return }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Folders left by runs that ended without cleaning up (a crash, a debugger stop) more than a day ago.
    /// Younger ones may belong to a run still going in another checkout.
    private static func removeStaleRuns(in root: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fileManager.removeItem(at: entry) }
        }
    }
}

/// A scratch folder for one test, removed when the test's value goes away.
nonisolated final class TemporaryDirectory {
    let url: URL

    init(_ name: String = "test") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoincideTests-\(name)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a file (and its folders) at a path relative to the scratch folder.
    @discardableResult
    func file(_ path: String, _ contents: String = "") throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// Creates a folder at a path relative to the scratch folder.
    @discardableResult
    func folder(_ path: String) throws -> URL {
        let folder = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
