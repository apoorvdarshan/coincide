import CoincideCore
import Darwin
import Foundation

/// A sealed UI-test app can exercise the bundled remote helper without an SSH
/// server. Ordinary app launches never receive this local transport factory.
enum NativeRemoteUITestingConnection {
    static let configuration = SSHRemoteEnvironmentConfiguration(target: "coincide-ui-script",
        helperPath: "/coincide-ui-testing/CoincideEnvironment", dataDirectory: "/coincide-ui-testing/RemoteScriptData")

    static func clientFactory(bundleIdentifier: String?, bundleURL: URL, environment: [String: String]) throws -> RemoteWorkspaceStore.ClientFactory? {
        guard let launch = try launch(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, environment: environment) else { return nil }
        return { configuration, expected in
            guard configuration == Self.configuration else { throw CocoaError(.fileReadNoPermission) }
            try launch.validate()
            return RemoteEnvironmentClient(factory: {
                try launch.validate()
                return try JSONRPCConnection(executable: launch.helper, arguments: launch.arguments(expected: expected),
                    cwd: launch.root, dialect: .jsonRPC2, maximumFrameSize: RemoteEnvironmentProtocol.maximumFrameBytes,
                    environment: launch.environment, drainProcessOnClose: true)
            }, expectedEnvironmentID: expected)
        }
    }

    struct Identity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }
    struct Launch: Sendable {
        let root: URL
        let helper: URL
        let environment: [String: String]
        let rootIdentity: Identity
        let helperIdentity: Identity
        var data: URL { root.appendingPathComponent("coincide-ui-testing-remote-script-host", isDirectory: true) }
        func arguments(expected: UUID?) -> [String] {
            var values = ["--stdio", "--data-directory", data.path, "--label", "Private UI script environment",
                "--codex-executable", "/usr/bin/false", "--codex-home", root.appendingPathComponent("remote-script-codex-home").path,
                "--claude-executable", "/usr/bin/false", "--claude-configuration-directory", root.appendingPathComponent("remote-script-claude-home").path,
                "--github-executable", "/usr/bin/false", "--github-configuration-directory", root.appendingPathComponent("remote-script-home/gh").path]
            if let expected { values += ["--expected-environment-id", expected.uuidString] }
            return values
        }
        func validate() throws {
            let currentRoot = try NativeRemoteUITestingConnection.identity(root, directory: true)
            let currentHelper = try NativeRemoteUITestingConnection.identity(helper, directory: false)
            guard currentRoot == rootIdentity, currentHelper == helperIdentity else {
                throw CocoaError(.fileReadNoPermission)
            }
            for path in [data, root.appendingPathComponent("remote-script-home"), root.appendingPathComponent("remote-script-codex-home"),
                         root.appendingPathComponent("remote-script-claude-home")] {
                _ = try NativeRemoteUITestingConnection.identity(path, directory: true)
            }
            if let configuration = environment["GIT_CONFIG_GLOBAL"], configuration != "/dev/null" {
                _ = try NativeRemoteUITestingConnection.privateFile(URL(fileURLWithPath: configuration))
            }
        }
    }

    static func launch(bundleIdentifier: String?, bundleURL: URL, environment: [String: String]) throws -> Launch? {
        #if DEBUG
        guard bundleIdentifier == AppLaunchConfiguration.uiTestingBundleIdentifier,
              environment["COINCIDE_UI_TESTING"] == "1", environment["COINCIDE_UI_TEST_REMOTE_SCRIPT"] == "1" else { return nil }
        guard let path = environment["COINCIDE_UI_TEST_ROOT"], path.hasPrefix("/"), !path.contains("\0") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("coincide-ui-testing-"), root.path.utf8.elementsEqual(path.utf8),
              root.resolvingSymlinksInPath().path.utf8.elementsEqual(path.utf8), bundleURL.isFileURL,
              bundleURL.pathExtension == "app" else { throw CocoaError(.fileReadNoPermission) }
        let rootIdentity = try identity(root, directory: true)
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/CoincideEnvironment").standardizedFileURL
        guard helper.resolvingSymlinksInPath().path.utf8.elementsEqual(helper.path.utf8) else { throw CocoaError(.fileReadNoPermission) }
        let helperIdentity = try identity(helper, directory: false)
        let pathValue = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard pathValue.utf8.count <= 16_384, !pathValue.contains("\0") else { throw CocoaError(.fileReadNoPermission) }
        let configuration = root.appendingPathComponent("gitconfig")
        let gitConfiguration: String
        if let captured = environment["GIT_CONFIG_GLOBAL"] {
            guard captured.utf8.elementsEqual(configuration.path.utf8) else { throw CocoaError(.fileReadNoPermission) }
            _ = try privateFile(configuration); gitConfiguration = configuration.path
        } else { gitConfiguration = "/dev/null" }
        let captured = ["PATH": pathValue, "HOME": root.appendingPathComponent("remote-script-home").path,
            "SHELL": "/bin/sh", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "GIT_CONFIG_GLOBAL": gitConfiguration,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "Never",
            "GH_CONFIG_DIR": root.appendingPathComponent("remote-script-home/gh").path]
        let value = Launch(root: root, helper: helper, environment: captured, rootIdentity: rootIdentity, helperIdentity: helperIdentity)
        try value.validate()
        return value
        #else
        return nil
        #endif
    }

    private static func identity(_ url: URL, directory: Bool) throws -> Identity {
        var node = stat()
        guard lstat(url.path, &node) == 0, node.st_uid == geteuid(),
              node.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              (directory ? node.st_mode & 0o777 == 0o700 : access(url.path, X_OK) == 0) else { throw CocoaError(.fileReadNoPermission) }
        return .init(device: UInt64(truncatingIfNeeded: node.st_dev), inode: node.st_ino)
    }
    private static func privateFile(_ url: URL) throws -> Identity {
        var node = stat()
        guard lstat(url.path, &node) == 0, node.st_uid == geteuid(), node.st_mode & S_IFMT == S_IFREG,
              node.st_mode & 0o777 == 0o600, node.st_nlink == 1 else { throw CocoaError(.fileReadNoPermission) }
        return .init(device: UInt64(truncatingIfNeeded: node.st_dev), inode: node.st_ino)
    }
}
