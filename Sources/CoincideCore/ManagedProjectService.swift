import Foundation
import Darwin

public struct ManagedProjectCreationResult: Sendable, Equatable {
    public let project: WorkspaceProject
    public let commitWarning: String?
    public init(project: WorkspaceProject, commitWarning: String? = nil) {
        self.project = project; self.commitWarning = commitWarning
    }
}

/// Creates app-managed repositories without changing Git identity, signing settings, or remotes.
/// A failed or cancelled setup always leaves its claimed folder available for recovery.
public struct ManagedProjectService: Sendable {
    public let root: URL
    private let environment: [String: String]?
    private let commitTimeout: Duration
    public init(root: URL) { self.root = root; environment = nil; commitTimeout = .seconds(30) }
    init(root: URL, environment: [String: String], commitTimeout: Duration = .seconds(30)) {
        self.root = root; self.environment = environment; self.commitTimeout = commitTimeout
    }

    public static func validatedName(_ name: String) throws -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CoincideError("Enter a project name.") }
        // Match the upstream contract's JavaScript string length, including surrogate pairs.
        guard title.utf16.count <= 200 else { throw CoincideError("Project names must be 200 characters or fewer.") }
        guard !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || CharacterSet.newlines.contains($0) }) else {
            throw CoincideError("Project names cannot contain control characters or line breaks.")
        }
        return title
    }

    /// Matches T3's NFKD ASCII folder naming; collision suffixes are added only when claiming.
    public static func folderName(for name: String) -> String {
        let normalized = name.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !(0x0300...0x036f).contains($0.value) }
        let lowered = String(String.UnicodeScalarView(normalized)).lowercased()
        var slug = "", separated = false
        for scalar in lowered.unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                if separated && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar); separated = false
            } else { separated = true }
            if slug.utf8.count >= 64 { break }
        }
        slug = String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { return "project" }
        let reserved = ["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] }
        return reserved.contains(slug) ? slug + "-project" : slug
    }

    public func create(name: String) async throws -> ManagedProjectCreationResult {
        try Task.checkCancellation()
        let title = try Self.validatedName(name)
        guard root.isFileURL else { throw CoincideError("The managed projects root must be a local folder.") }
        var claimed: URL?
        do {
            let projects = root.standardizedFileURL
            try prepareRoot(projects)
            try Task.checkCancellation()
            let folder = try claim(Self.folderName(for: title), in: projects)
            claimed = folder
            try Task.checkCancellation()
            let settings = try await run(["config", "--null", "--get", "init.defaultBranch"], at: folder)
            let branch: String
            if settings.status == 0 {
                let bytes = settings.output.last == 0 ? settings.output.dropLast() : settings.output[...]
                guard let configured = String(data: bytes, encoding: .utf8), !configured.isEmpty else { throw CoincideError("Git's configured initial branch is empty or invalid.") }
                branch = configured
            } else { branch = "main" }
            try await checked(["init", "--initial-branch", branch], at: folder, repository: true)
            try Task.checkCancellation()
            try writeNew(Self.readme(title), to: folder.appendingPathComponent("README.md"))
            let assets = folder.appendingPathComponent("assets")
            guard mkdir(assets.path, 0o700) == 0 else { throw CoincideError("Could not create the project's assets folder without overwriting an existing path.") }
            try writeNew(Self.icon(title), to: assets.appendingPathComponent("icon.svg"))
            try await checked(["add", "--force", "--", "README.md", "assets/icon.svg"], at: folder, repository: true)
            var warning: String?
            do {
                let result = try await run(["commit", "--message", "Initial commit"], at: folder, repository: true, timeout: commitTimeout)
                if result.status != 0 { warning = Self.commitFailure(result.error) }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                warning = "The project is ready, but the initial commit failed: " + Self.diagnostic(error.localizedDescription)
            }
            try Task.checkCancellation()
            var project = WorkspaceProject(path: folder.path); project.name = title
            return .init(project: project, commitWarning: warning)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let detail = Self.diagnostic(error.localizedDescription)
            if let claimed { throw CoincideError("Project setup failed. The folder was preserved at \(claimed.path). \(detail)") }
            throw CoincideError("Could not create the project. " + detail)
        }
    }

    private func prepareRoot(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw CoincideError("The managed projects root is not a directory. Existing files and symlinks were left untouched.") }
            return
        }
        guard errno == ENOENT else { throw CoincideError("The managed projects root could not be inspected.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CoincideError("The managed projects root changed while it was being created.") }
    }
    private func claim(_ slug: String, in directory: URL) throws -> URL {
        for attempt in 1...100 {
            try Task.checkCancellation()
            let candidate = directory.appendingPathComponent(attempt == 1 ? slug : slug + "-" + String(attempt))
            if mkdir(candidate.path, 0o700) == 0 { return candidate }
            if errno == EEXIST { continue }
            throw CoincideError("Could not create \(candidate.path) without overwriting an existing path.")
        }
        throw CoincideError("All 100 folder names for \(slug) are taken. Choose a different project name.")
    }
    private func writeNew(_ text: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CoincideError("Could not create \(url.lastPathComponent) without overwriting an existing file.") }
        defer { close(descriptor) }
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count } else if count < 0 && errno == EINTR { continue }
                else { throw CoincideError("Could not finish writing \(url.lastPathComponent). Its existing bytes were preserved.") }
            }
        }
    }
    private func run(_ arguments: [String], at folder: URL, repository: Bool = false, timeout: Duration = .seconds(10)) async throws -> CommandResult {
        var env = environment ?? ProcessChannel.environment()
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CURL_VERBOSE"] + env.keys.filter({ $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") || $0.hasPrefix("GIT_TRACE") }) {
            env.removeValue(forKey: key)
        }
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GCM_INTERACTIVE"] = "Never"; env["GIT_ASKPASS"] = "/usr/bin/false"; env["LC_ALL"] = "C"
        var prefix = ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "color.ui=false", "-C", folder.path]
        if repository { prefix += ["-c", "core.bare=false", "--git-dir=" + folder.appendingPathComponent(".git").path, "--work-tree=" + folder.path] }
        return try await CommandRunner.run("git", prefix + arguments, cwd: folder, limit: 65_536, timeout: timeout, environment: env)
    }
    private func checked(_ arguments: [String], at folder: URL, repository: Bool) async throws {
        let result = try await run(arguments, at: folder, repository: repository)
        guard result.status == 0 else { throw CoincideError(Self.diagnostic(String(decoding: result.error, as: UTF8.self), fallback: "Git failed (exit \(result.status)).")) }
    }
    private static func diagnostic(_ text: String, fallback: String = "Git could not complete the operation.") -> String {
        let value = GitService.redactURLs(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(2_000))
    }
    private static func commitFailure(_ bytes: Data) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let lower = text.lowercased()
        if lower.contains("identity unknown") || lower.contains("tell me who you are") || lower.contains("no name was given") || lower.contains("no email was given") || lower.contains("unable to auto-detect email") {
            return "The project is ready, but Git needs your user.name and user.email before the first commit. Configure your identity, then commit the staged starter files."
        }
        return "The project is ready, but Git could not make the initial commit. " + diagnostic(text)
    }
    private static func readme(_ name: String) -> String {
        "<img src=\"assets/icon.svg\" width=\"64\" height=\"64\" alt=\"Project icon\">\n\n# \(name)\n\nCreated in [Coincide](https://github.com/apoorvdarshan/coincide).\n"
    }
    private static func icon(_ name: String) -> String {
        let title = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img">
          <title>\(title)</title>
          <rect width="64" height="64" rx="14" fill="#2563eb"/>
          <path d="M16 16h25a5 5 0 0 1 5 5v14a5 5 0 0 1-5 5H26l-9 7V21a5 5 0 0 1 5-5" fill="none" stroke="#ffffff" stroke-width="3" stroke-linejoin="round"/>
          <path d="M27 25h21v23l-7-5H30a5 5 0 0 1-5-5V27" fill="#2563eb" stroke="#ffffff" stroke-width="3" stroke-linejoin="round"/>
        </svg>

        """
    }
}
