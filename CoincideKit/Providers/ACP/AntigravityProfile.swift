import Foundation

/// Where Coincide keeps Antigravity under its data folder (`~/Library/Application Support/Coincide`,
/// or `COINCIDE_DATA_DIR`), laid out as T3 Code lays out its state folder:
///
///     tools/antigravity-acp/darwin-arm64/versions/<archive SHA-256>/   one folder per release
///     tools/antigravity-acp/darwin-arm64/current -> versions/<…>         the active release
///     providers/antigravity/default/                                     the private Google profile
public struct AntigravityPaths: Sendable, Hashable {
    public var dataDirectory: URL
    public var architecture: String

    public nonisolated init(dataDirectory: URL, architecture: String = AntigravityRelease.hostArchitecture) {
        self.dataDirectory = dataDirectory
        self.architecture = architecture
    }

    public nonisolated static var standard: AntigravityPaths { AntigravityPaths(dataDirectory: coincideDataDirectory) }

    /// The same folder `AppStore.defaultDirectory` uses.
    nonisolated static var coincideDataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coincide", isDirectory: true)
    }

    /// The downloaded runtime for this Mac's architecture.
    public nonisolated var managedDirectory: URL {
        dataDirectory.appendingPathComponent("tools/antigravity-acp", isDirectory: true)
            .appendingPathComponent(AntigravityRelease.platformKey(architecture: architecture), isDirectory: true)
    }

    nonisolated var versionsDirectory: URL { managedDirectory.appendingPathComponent("versions", isDirectory: true) }
    /// A symbolic link to the active release's folder, replaced atomically on each install.
    nonisolated var currentLink: URL { managedDirectory.appendingPathComponent("current") }

    /// The executable of the active release, through `current`. Before launching, the runtime
    /// resolves and leases its immutable executable/helper pair together.
    public nonisolated var managedExecutable: URL { currentLink.appendingPathComponent(AntigravityRelease.executableName) }

    public nonisolated var profileDirectory: URL {
        dataDirectory.appendingPathComponent("providers/antigravity/default", isDirectory: true)
    }

    /// Whether `url` is inside the downloaded runtime, after resolving symbolic links.
    public nonisolated func isManaged(_ url: URL) -> Bool {
        Self.canonicalPath(url).hasPrefix(Self.canonicalPath(managedDirectory) + "/")
    }

    /// `url` with every symbolic link resolved (`realpath`), also when its last components do not
    /// exist yet, so two spellings of one place always compare equal.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        var base = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = realpath(base.path, nil) {
                defer { free(resolved) }
                let path = String(cString: resolved)
                return missing.reversed().reduce(path) { ($0 == "/" ? "" : $0) + "/" + $1 }
            }
            guard base.path != "/", !base.path.isEmpty else { return url.standardizedFileURL.path }
            missing.append(base.lastPathComponent)
            base = base.deletingLastPathComponent()
        }
    }
}

public struct AntigravityProfileError: LocalizedError, Equatable {
    public var message: String
    public nonisolated var errorDescription: String? { message }
}

/// Antigravity's private Google profile: a `GEMINI_HOME` that belongs to Coincide, not the user's
/// `~/.gemini`, as T3 Code isolates it. The sign-in token (kept as a file), settings, conversations,
/// hooks and MCP servers stay apart from any other Antigravity or Gemini install; the user's own
/// skills are linked in.
///
/// Every launch also points `BROWSER` at a small helper that hands the sign-in link back to Coincide
/// on stderr instead of opening a browser, so Google sign-in only ever starts from Settings.
public struct AntigravityProfile: Sendable, Hashable {
    /// What the browser helper prints before the link it was given.
    public nonisolated static let browserMarker = "__COINCIDE_ANTIGRAVITY_AUTH_URL__"
    /// T3 Code's `ANTIGRAVITY_SIGN_IN_REQUIRED_MESSAGE`.
    public nonisolated static var signInRequiredMessage: String {
        String(localized: "Sign in to Antigravity in Settings before you continue.")
    }

    nonisolated static let preflightURL = "https://example.invalid/coincide-antigravity-browser-preflight"

    /// Variables that would bypass the private profile or switch Antigravity from the user's Google
    /// subscription to billed API access (T3 Code's list). Compared case-insensitively.
    nonisolated static let removedEnvironmentKeys: Set<String> = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT",
        "CLOUDSDK_CORE_PROJECT", "AGY_ACP_CCPA_PROJECT", "AGY_ACP_ENABLE_OAUTH", "GEMINI_HOME",
        "AGY_ACP_FORCE_FILE_STORAGE", "ANTIGRAVITY_HARNESS_PATH", "BROWSER", "PYTHONUNBUFFERED", "ELECTRON_RUN_AS_NODE",
    ]

    public var geminiHome: URL
    /// The user's home, whose `~/.gemini` skills are linked into the profile.
    public var userHome: URL

    public nonisolated init(geminiHome: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.geminiHome = geminiHome.standardizedFileURL
        self.userHome = userHome
    }

    public nonisolated static var standard: AntigravityProfile { AntigravityProfile(geminiHome: AntigravityPaths.standard.profileDirectory) }

    nonisolated var acpDirectory: URL { geminiHome.appendingPathComponent("antigravity-acp", isDirectory: true) }
    /// Where Antigravity keeps the Google sign-in (`AGY_ACP_FORCE_FILE_STORAGE`).
    public nonisolated var tokenFile: URL { acpDirectory.appendingPathComponent("acp_token.json") }
    nonisolated var settingsFile: URL { acpDirectory.appendingPathComponent("settings.json") }
    nonisolated var browserHelper: URL { geminiHome.appendingPathComponent("coincide-browser.sh") }

    /// Whether the profile holds a Google sign-in. Like T3 Code's usage check, this reads only the
    /// token file; whether Google still accepts it shows when a session starts.
    public nonisolated var isSignedIn: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: tokenFile.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Python's `webbrowser` runs this for the sign-in link: the helper, then `%s` for the link.
    /// Each word is single-quoted for `shlex`, and the whole must not contain `:` because Python
    /// splits `BROWSER` on the path separator before it parses quotes.
    public nonisolated var browserCommand: String {
        ["/bin/sh", browserHelper.path, "%s"].map(Self.quote).joined(separator: " ")
    }

    /// The agent's environment: `base` without anything that would leave the profile, plus the
    /// profile, file token storage, the browser helper and the harness next to the executable.
    public nonisolated func environment(_ base: [String: String], harness: URL) -> [String: String] {
        var environment = base.filter { !Self.removedEnvironmentKeys.contains($0.key.uppercased()) }
        environment["GEMINI_HOME"] = geminiHome.path
        environment["AGY_ACP_FORCE_FILE_STORAGE"] = "1"
        environment["BROWSER"] = browserCommand
        environment["PYTHONUNBUFFERED"] = "1"
        environment["ANTIGRAVITY_HARNESS_PATH"] = harness.path
        return environment
    }

    /// Creates the profile's private folders, writes its settings and the browser helper, checks that
    /// the helper really reports links instead of opening a browser, and links the user's skills.
    /// Safe to run before every launch.
    public nonisolated func prepare(environment base: [String: String]) async throws {
        let helperPath = browserHelper.path
        guard !browserCommand.contains(":"), !helperPath.contains("%s"),
            helperPath.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n\0")) == nil
        else {
            throw AntigravityProfileError(
                message: String(
                    localized:
                        "Coincide’s data folder path contains a character that stops Antigravity’s browser launches from being redirected to Coincide. Move the data folder to a path without colons."
                ))
        }
        let manager = FileManager.default
        do {
            for directory in [geminiHome, acpDirectory] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        } catch {
            throw AntigravityProfileError(message: String(localized: "The Antigravity profile folder could not be created."))
        }
        do {
            try Self.write(Data(Self.helperScript.utf8), to: browserHelper, permissions: 0o700)
        } catch {
            throw AntigravityProfileError(message: String(localized: "Antigravity’s browser helper could not be written."))
        }
        try await verifyBrowserHelper(environment: environment(base, harness: URL(fileURLWithPath: "/dev/null")))
        do {
            // `auth.type` names the method, so a native sign-out clears only its credentials.
            try Self.write(Data(#"{"auth":{"type":"oauth-personal"}}"#.utf8 + [0x0A]), to: settingsFile, permissions: 0o600)
        } catch {
            throw AntigravityProfileError(message: String(localized: "The Antigravity profile settings could not be written."))
        }
        linkUserSkills()
    }

    /// Runs the helper as Python would and expects exactly the marked link on stderr (T3 Code's preflight).
    nonisolated func verifyBrowserHelper(environment: [String: String]) async throws {
        let result = await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"), [browserHelper.path, Self.preflightURL], environment: environment, timeout: 5)
        guard result.status == 0, result.stdout.isEmpty, result.stderr == Self.browserMarker + Self.preflightURL + "\n" else {
            throw AntigravityProfileError(message: String(localized: "Antigravity’s browser suppression could not be verified."))
        }
    }

    /// The private profile has its own skill folders; point them at the user's (T3 Code's
    /// `linkAntigravityUserSkills`). A folder that is not a link is left alone.
    nonisolated func linkUserSkills() {
        let manager = FileManager.default
        let userGemini = userHome.appendingPathComponent(".gemini", isDirectory: true)
        for relative in ["config/skills", "antigravity-cli/skills"] {
            let link = geminiHome.appendingPathComponent(relative)
            let target = userGemini.appendingPathComponent(relative)
            if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
                let resolved = URL(fileURLWithPath: existing, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
                if resolved.path == target.standardizedFileURL.path { continue }
                try? manager.removeItem(at: link)
            } else if (try? manager.attributesOfItem(atPath: link.path)) != nil {
                continue
            }
            try? manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        }
    }

    /// Removes what a throwaway session left in the profile (T3 Code's `removeAntigravitySessionFiles`):
    /// only when its metadata names `cwd`, the unique folder the session was created in.
    public nonisolated func removeSessionFiles(sessionID: String, cwd: URL) {
        guard sessionID.range(of: Self.uuidV4Pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return }
        let conversations = acpDirectory.appendingPathComponent("conversations", isDirectory: true)
        let meta = conversations.appendingPathComponent(sessionID + ".meta")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: meta.path),
            (attributes[.size] as? NSNumber)?.intValue ?? .max <= 64 * 1_024,
            let data = try? Data(contentsOf: meta), let recorded = JSONValue.parse(String(decoding: data, as: UTF8.self))?["cwd"]?.string,
            AntigravityPaths.canonicalPath(URL(fileURLWithPath: recorded)) == AntigravityPaths.canonicalPath(cwd)
        else { return }
        for suffix in [".db", ".db-wal", ".db-shm", ".db-journal", ".meta"] {
            try? FileManager.default.removeItem(at: conversations.appendingPathComponent(sessionID + suffix))
        }
        try? FileManager.default.removeItem(at: acpDirectory.appendingPathComponent("brain", isDirectory: true).appendingPathComponent(sessionID))
    }

    private nonisolated static let uuidV4Pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    /// Ignores SIGPIPE and always exits 0: a failing helper would make Python fall back to opening a
    /// real browser. A link with a line break is dropped rather than split into a look-alike line.
    nonisolated static var helperScript: String {
        """
        #!/bin/sh
        # Written by Coincide. Antigravity runs this instead of a web browser; Coincide shows the link.
        trap '' PIPE
        cr=$(printf '\\r')
        case $1 in
        *"$cr"* | *'
        '*) exit 0 ;;
        esac
        printf '%s%s\\n' '\(browserMarker)' "$1" >&2
        exit 0

        """
    }

    nonisolated static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    /// Replaces `url` only when its contents change, through a temporary file and a rename.
    nonisolated static func write(_ data: Data, to url: URL, permissions: Int) throws {
        let manager = FileManager.default
        if let existing = try? Data(contentsOf: url), existing == data {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
            return
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// A Google sign-in link Antigravity printed: only Google's OAuth page, asking for a code that comes
/// back to a loopback port on this Mac, is accepted (T3 Code's `parseAntigravityAuthorizationUrl`).
public struct AntigravityAuthorization: Sendable, Hashable {
    public var url: URL
    /// `http://127.0.0.1:<port>/`, where the agent waits for Google's answer.
    public var redirectURI: String
    public var state: String

    public nonisolated static let maxLength = 16_384

    public nonisolated static func parse(_ text: String) -> AntigravityAuthorization? {
        guard text.utf8.count <= maxLength, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            let components = URLComponents(string: text), components.scheme == "https",
            components.host == "accounts.google.com", components.port == nil || components.port == 443,
            components.path == "/o/oauth2/v2/auth", components.user == nil, components.password == nil,
            components.fragment == nil, let url = components.url
        else { return nil }
        let states = formValues(components, "state")
        let redirects = formValues(components, "redirect_uri")
        let responseTypes = formValues(components, "response_type")
        guard states.count == 1, let state = states.first, !state.isEmpty, state.count <= 512,
            state.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, responseTypes == ["code"], redirects.count == 1,
            let redirect = redirects.first, loopbackPort(redirect) != nil
        else { return nil }
        return AntigravityAuthorization(url: url, redirectURI: redirect, state: state)
    }

    /// The port of `http://127.0.0.1:<port>/`, when it is an unprivileged one.
    nonisolated static func loopbackPort(_ redirect: String) -> Int? {
        guard let match = redirect.wholeMatch(of: /http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})\//), let port = Int(match.1),
            (1_024...65_535).contains(port)
        else { return nil }
        return port
    }

    /// Query values decoded as a browser's `URLSearchParams` decodes them (`+` is a space).
    nonisolated static func formValues(_ components: URLComponents, _ name: String) -> [String] {
        (components.percentEncodedQueryItems ?? []).compactMap { item in
            guard item.name.removingPercentEncoding == name else { return nil }
            return (item.value ?? "").replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
        }
    }
}
