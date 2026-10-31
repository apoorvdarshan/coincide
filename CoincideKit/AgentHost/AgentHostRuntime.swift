import CryptoKit
import Darwin
import Foundation
import Security

/// The agent host runs from its own copy of its build, never from inside Coincide.app.
///
/// Why: macOS checks a process's code signature against its files on disk. Once an update replaces Coincide.app,
/// a host started from inside it still runs, but its files are the new build's, so its signature no longer checks
/// out and the app refuses its replies (seen 1 Nov 2026: "Received message forbidden due to code signing
/// requirement"). The app could then neither reattach to the agents it still ran nor ask it anything, and started
/// the same sessions a second time with `--resume`.
///
/// So launchd starts the host from the bundle, and before doing anything else it copies its build (the host app and
/// the frameworks it links, laid out as in Coincide.app so `@executable_path/../../../../Frameworks` still finds
/// them) into `runtime/<build>-<digest>` in its folder and `exec`s the copy. `exec` keeps the process launchd started,
/// so it still owns the Mach service. Nothing replaces a copy while a host runs from it (`holdInUse`); copies nobody
/// uses are removed (`prune`). If anything fails, the host runs from the bundle as before.
public enum AgentHostRuntime {
    /// Set on the copy's environment: it runs from its runtime folder, and must not copy itself again.
    public nonisolated static let relocatedVariable = "COINCIDE_AGENT_HOST_RUNTIME"
    /// The Coincide.app the copy came from, which a notification click opens.
    public nonisolated static let appBundleVariable = "COINCIDE_APP_BUNDLE"
    /// `1` keeps the host running from the bundle, for diagnosing.
    public nonisolated static let inPlaceVariable = "COINCIDE_AGENT_HOST_IN_PLACE"

    nonisolated static let completeMarker = ".complete"
    nonisolated static let attemptMarker = ".launch-attempt"
    nonisolated static let launchedMarker = ".launched"
    nonisolated static let disabledMarker = ".disabled"
    nonisolated static let inUseLock = ".in-use"

    /// A host as Coincide.app holds it.
    public struct Source: Sendable, Equatable {
        public var appBundle: URL
        public var hostBundle: URL
        public var frameworks: [URL]
        public var build: String

        public nonisolated init(appBundle: URL, hostBundle: URL, frameworks: [URL], build: String) {
            self.appBundle = appBundle
            self.hostBundle = hostBundle
            self.frameworks = frameworks
            self.build = build
        }

        /// The host at `Coincide.app/Contents/Helpers/CoincideAgentHost.app`, with every framework in the app's
        /// `Contents/Frameworks`. Nil for a host anywhere else (a copy already, or a build folder).
        public nonisolated static func bundled(hostBundle: URL, build: String) -> Source? {
            let helpers = hostBundle.deletingLastPathComponent()
            let contents = helpers.deletingLastPathComponent()
            let app = contents.deletingLastPathComponent()
            guard hostBundle.pathExtension == "app", helpers.lastPathComponent == "Helpers",
                contents.lastPathComponent == "Contents", app.pathExtension == "app"
            else { return nil }
            let folder = contents.appendingPathComponent("Frameworks", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let frameworks = names.filter { $0.hasSuffix(".framework") }.sorted().map { folder.appendingPathComponent($0) }
            return Source(appBundle: app, hostBundle: hostBundle, frameworks: frameworks, build: build)
        }
    }

    /// Checks a bundle's code signature; true when it may run.
    public typealias Validator = (URL) -> Bool
    /// The bundle's code identity (its cdhash), so a copy is only ever of exactly the code the bundle holds.
    public typealias Identity = (URL) -> String?

    /// Copies the source into its runtime folder unless a good copy is there, and returns the copy's host executable
    /// to `exec`. Nil means run from the bundle: the copy failed or didn't validate, or a copy of this build failed to
    /// start before (`disabledMarker`), so the host doesn't fail the same way on every launch.
    public nonisolated static func prepare(
        _ source: Source, runtimeRoot: URL, validate: Validator, identity: Identity
    ) -> URL? {
        let fileManager = FileManager.default
        guard let name = folderName(source, identity: identity) else { return nil }
        let folder = runtimeRoot.appendingPathComponent(name, isDirectory: true)
        let host = folder.appendingPathComponent("Contents/Helpers/\(source.hostBundle.lastPathComponent)")
        if fileManager.fileExists(atPath: folder.appendingPathComponent(disabledMarker).path) { return nil }
        // A copy that was started but died before the app ever reached it is not tried again.
        if !fileManager.fileExists(atPath: folder.appendingPathComponent(launchedMarker).path),
            let attempt = try? String(contentsOf: folder.appendingPathComponent(attemptMarker), encoding: .utf8),
            let pid = pid_t(attempt.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            guard pid != getpid(), kill(pid, 0) != 0 else { return nil }
            fileManager.createFile(atPath: folder.appendingPathComponent(disabledMarker).path, contents: nil)
            return nil
        }
        let isComplete = fileManager.fileExists(atPath: folder.appendingPathComponent(completeMarker).path)
        if !isComplete || !validates(folder: folder, source: source, validate: validate) {
            guard install(source, into: folder, runtimeRoot: runtimeRoot, validate: validate) else { return nil }
        }
        guard (try? "\(getpid())".write(to: folder.appendingPathComponent(attemptMarker), atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return host.appendingPathComponent("Contents/MacOS").appendingPathComponent(
            source.hostBundle.deletingPathExtension().lastPathComponent)
    }

    /// `<build>-<digest of every bundle's identity>`: one folder per exact build, so two builds that share a build
    /// number (local builds of one commit) never share a copy.
    nonisolated static func folderName(_ source: Source, identity: Identity) -> String? {
        var hasher = SHA256()
        for bundle in [source.hostBundle] + source.frameworks {
            guard let id = identity(bundle) else { return nil }
            hasher.update(data: Data("\(bundle.lastPathComponent)=\(id);".utf8))
        }
        let build = source.build.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let digest = hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(build.isEmpty ? "0" : build)-\(digest)"
    }

    private nonisolated static func validates(folder: URL, source: Source, validate: Validator) -> Bool {
        let host = folder.appendingPathComponent("Contents/Helpers/\(source.hostBundle.lastPathComponent)")
        guard validate(host) else { return false }
        return source.frameworks.allSatisfy {
            validate(folder.appendingPathComponent("Contents/Frameworks/\($0.lastPathComponent)"))
        }
    }

    /// Copies into a private folder first and moves it into place once it validates, so a copy is whole or absent.
    private nonisolated static func install(_ source: Source, into folder: URL, runtimeRoot: URL, validate: Validator) -> Bool {
        let fileManager = FileManager.default
        let partial = runtimeRoot.appendingPathComponent(".\(folder.lastPathComponent).\(getpid()).partial", isDirectory: true)
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let helpers = partial.appendingPathComponent("Contents/Helpers", isDirectory: true)
            let frameworks = partial.appendingPathComponent("Contents/Frameworks", isDirectory: true)
            try fileManager.createDirectory(at: helpers, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source.hostBundle, to: helpers.appendingPathComponent(source.hostBundle.lastPathComponent))
            for framework in source.frameworks {
                try fileManager.copyItem(at: framework, to: frameworks.appendingPathComponent(framework.lastPathComponent))
            }
            guard validates(folder: partial, source: source, validate: validate) else {
                try? fileManager.removeItem(at: partial)
                return false
            }
            fileManager.createFile(atPath: partial.appendingPathComponent(completeMarker).path, contents: nil)
            // An incomplete or invalid copy of the same name is unused: a host only runs from a complete one.
            if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
            try fileManager.moveItem(at: partial, to: folder)
            return true
        } catch {
            try? fileManager.removeItem(at: partial)
            return false
        }
    }

    /// Called by the copy once the app reached it: this copy works, so it is used again.
    public nonisolated static func markLaunched(runtimeFolder: URL) {
        let marker = runtimeFolder.appendingPathComponent(launchedMarker).path
        if !FileManager.default.fileExists(atPath: marker) { FileManager.default.createFile(atPath: marker, contents: nil) }
    }

    /// The runtime folder a copy's executable is in: `<folder>/Contents/Helpers/X.app/Contents/MacOS/X`.
    public nonisolated static func runtimeFolder(ofExecutable executable: URL) -> URL {
        var url = executable
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    /// Shared-locks the copy for as long as this process runs, so `prune` never removes it. Returns the open file,
    /// which must stay open; the kernel lets go of it when the process exits.
    public nonisolated static func holdInUse(runtimeFolder: URL) -> Int32? {
        let fd = open(runtimeFolder.appendingPathComponent(inUseLock).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Removes the copies no host runs from, except `keeping`, and copies left half made. `unregister` is called
    /// with each host bundle before it goes, so Launch Services forgets it.
    public nonisolated static func prune(runtimeRoot: URL, keeping: String?, unregister: (URL) -> Void = { _ in }) {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: runtimeRoot.path)) ?? []
        for name in names where name != keeping {
            let folder = runtimeRoot.appendingPathComponent(name, isDirectory: true)
            if name.hasSuffix(".partial") {
                // Another host may be making it right now; one left for an hour was abandoned.
                let modified = (try? fileManager.attributesOfItem(atPath: folder.path)[.modificationDate]) as? Date
                if let modified, Date().timeIntervalSince(modified) > 3_600 { try? fileManager.removeItem(at: folder) }
                continue
            }
            let fd = open(folder.appendingPathComponent(inUseLock).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            // A host runs from it.
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            let helpers = folder.appendingPathComponent("Contents/Helpers", isDirectory: true)
            for bundle in (try? fileManager.contentsOfDirectory(atPath: helpers.path)) ?? [] where bundle.hasSuffix(".app") {
                unregister(helpers.appendingPathComponent(bundle))
            }
            try? fileManager.removeItem(at: folder)
        }
    }

    // MARK: Code signing

    /// Whether the bundle is signed by `team` (and has `identifier`, when given), checked against its files.
    public nonisolated static func isSigned(_ bundle: URL, identifier: String?, team: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text =
            identifier.map { "anchor apple generic and identifier \"\($0)\" and certificate leaf[subject.OU] = \"\(team)\"" }
            ?? "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The bundle's cdhash, read from its signature without hashing its files.
    public nonisolated static func codeIdentity(_ bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
