import AppKit
import CoincideKit

/// Runs the host from its own copy of this build (`AgentHostRuntime`), and looks after those copies.
enum AgentHostRelocation {
    /// The runtime folder this host runs from, when it is a copy.
    private(set) static var runtimeFolder: URL?
    /// Keeps the copy in use (`AgentHostRuntime.holdInUse`) for as long as the host runs.
    nonisolated(unsafe) private static var inUse: Int32?
    /// The Coincide.app the copy came from.
    private static var sourceApp: URL?

    private static var runtimeRoot: URL { AgentHostPaths.directory().appendingPathComponent("runtime", isDirectory: true) }

    /// Copies this build and `exec`s the copy, unless this is the copy already, the build isn't signed by a team (the
    /// copy's signature could not be checked), or `COINCIDE_AGENT_HOST_IN_PLACE=1`. Returns only to run from here.
    static func execCopyIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        if environment[AgentHostRuntime.relocatedVariable] != nil {
            runtimeFolder = Bundle.main.executableURL.map(AgentHostRuntime.runtimeFolder(ofExecutable:))
            sourceApp = environment[AgentHostRuntime.appBundleVariable].map { URL(fileURLWithPath: $0) }
            // Read once; the agents the host starts don't inherit them.
            unsetenv(AgentHostRuntime.relocatedVariable)
            unsetenv(AgentHostRuntime.appBundleVariable)
            return
        }
        guard environment[AgentHostRuntime.inPlaceVariable] != "1", let team = AgentHostIdentity.currentTeam(),
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            let source = AgentHostRuntime.Source.bundled(hostBundle: Bundle.main.bundleURL, build: build)
        else { return }
        let hostID = Bundle.main.bundleIdentifier
        let hostBundle = source.hostBundle.lastPathComponent
        guard
            let executable = AgentHostRuntime.prepare(
                source, runtimeRoot: runtimeRoot,
                validate: { bundle in
                    AgentHostRuntime.isSigned(bundle, identifier: bundle.lastPathComponent == hostBundle ? hostID : nil, team: team)
                },
                identity: AgentHostRuntime.codeIdentity)
        else { return }
        var variables = environment
        variables[AgentHostRuntime.relocatedVariable] = "1"
        variables[AgentHostRuntime.appBundleVariable] = source.appBundle.path
        let arguments = [executable.path] + CommandLine.arguments.dropFirst()
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(executable.path, argv, envp)
        // Still here: the copy could not be run. Nothing of this process changed, so it goes on from the bundle.
    }

    /// Once the host listens for the app: keeps its copy from being removed, and removes the copies of other builds
    /// that no host runs any more.
    static func didStart() {
        guard let runtimeFolder else {
            prune(keeping: nil)
            return
        }
        inUse = AgentHostRuntime.holdInUse(runtimeFolder: runtimeFolder)
        prune(keeping: runtimeFolder.lastPathComponent)
    }

    /// The app reached this copy: it works as the LaunchAgent, so it is used again. Until then a copy counts as one
    /// that failed (`AgentHostRuntime.prepare`), so a copy launchd can't deliver connections to is given up on.
    nonisolated static func didAcceptConnection() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let runtimeFolder, !hasAccepted else { return }
                hasAccepted = true
                AgentHostRuntime.markLaunched(runtimeFolder: runtimeFolder)
            }
        }
    }

    private static var hasAccepted = false

    private static func prune(keeping: String?) {
        let root = runtimeRoot
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            AgentHostRuntime.prune(runtimeRoot: root, keeping: keeping) { bundle in
                let lsregister = URL(
                    fileURLWithPath:
                        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
                let process = Process()
                process.executableURL = lsregister
                process.arguments = ["-u", bundle.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

    /// The Coincide.app to open for a notification click: the one the copy came from, or the bundle the host is in.
    static var appBundle: URL? {
        if let sourceApp { return sourceApp }
        // Coincide.app, three folders up from Contents/Helpers/CoincideAgentHost.app.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if app.pathExtension == "app" { return app }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentHostIdentity.appBundleID)
    }
}
