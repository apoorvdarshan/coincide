import Foundation
import Testing
@testable import CoincideCore

@Test func sourceControlDiscoveryParsesVersionsAndGhAuthStatusWithoutCredentials() throws {
    #expect(SourceControlDiscovery.parseVersion("git version 2.39.5 (Apple Git-154)\n") == "2.39.5")
    #expect(SourceControlDiscovery.parseVersion("gh version 2.81.0 (2025-10-01)\nhttps://github.com/cli/cli/releases/tag/v2.81.0\n") == "2.81.0")
    #expect(SourceControlDiscovery.parseVersion("nonsense") == nil)
    #expect(SourceControlDiscovery.compareVersions("2.81.0", "2.81.0") == .orderedSame)
    #expect(SourceControlDiscovery.compareVersions("2.9", "2.81.0") == .orderedAscending)
    #expect(SourceControlDiscovery.compareVersions("3.0", "2.81.0") == .orderedDescending)
    let json = Data(#"{"hosts":{"github.com":[{"state":"success","active":false,"host":"github.com","login":"secondary","tokenSource":"keyring"},{"state":"success","active":true,"host":"github.com","login":"octocat","tokenSource":"GH_TOKEN","scopes":"repo"}],"ghe.example.invalid":[{"state":"error","active":true,"host":"ghe.example.invalid","login":"worker","tokenSource":"/Users/private/.config/gh/hosts.yml","error":"The token is invalid."}]}}"#.utf8)
    let accounts = try #require(SourceControlDiscovery.parseAuthStatusJSON(json))
    #expect(accounts.count == 3)
    #expect(accounts.first { $0.login == "octocat" }?.environmentVariable == "GH_TOKEN")
    let enterprise = try #require(accounts.first { $0.host == "ghe.example.invalid" })
    #expect(!enterprise.authenticated && enterprise.error == "The token is invalid." && enterprise.tokenSource == "hosts.yml")
    let host = SourceControlHostStatus(host: "github.com", accounts: accounts.filter { $0.host == "github.com" }, usedByProjects: true)
    #expect(host.effectiveAccount?.login == "octocat")
    #expect(SourceControlDiscovery.parseAuthStatusJSON(Data("{}".utf8)) == nil)
    let text = """
    github.com
      ✓ Logged in to github.com account octocat (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
      ✓ Logged in to github.com account second (keyring)
      - Active account: false
    ghe.example.invalid
      X Failed to log in to ghe.example.invalid account worker (/Users/private/.config/gh/hosts.yml)
      - Active account: true
      - The token in /Users/private/.config/gh/hosts.yml is invalid.
    """
    let parsed = SourceControlDiscovery.parseAuthStatusText(text)
    #expect(parsed.map(\.login) == ["octocat", "second", "worker"])
    #expect(parsed[0].active && !parsed[1].active && !parsed[2].authenticated && parsed[2].tokenSource == "hosts.yml")
    #expect(!parsed.contains { ($0.tokenSource ?? "").contains("gho_") })
}

@Test(.timeLimit(.minutes(1))) func sourceControlDiscoveryRunsOnlyReadOnlyGhCommandsAndFallsBackForOldCLI() async throws {
    let root = try temporaryWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("gh.log")
    func fake(_ name: String, version: String, json: Bool) throws -> URL {
        let url = root.appendingPathComponent(name)
        let status = json ? #"printf '%s' '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"octocat","tokenSource":"keyring"}]}}'; exit 1"#
            : "echo 'github.com' >&2; echo '  ✓ Logged in to github.com as legacy (oauth_token)' >&2; exit 0"
        try """
        #!/bin/sh
        echo "$@" >> '\(log.path)'
        if [ "$1" = "--version" ]; then echo 'gh version \(version) (2025-01-01)'; exit 0; fi
        if [ "$1 $2" = "auth status" ]; then
          if [ "$3" = "--json" ] && [ "\(json ? "1" : "0")" = "0" ]; then echo 'unknown flag: --json' >&2; exit 1; fi
          \(status)
        fi
        exit 2
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    var environment = ProcessInfo.processInfo.environment
    for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST"] { environment.removeValue(forKey: key) }
    let modern = SourceControlDiscovery(environment: environment, gitExecutable: ProcessChannel.findExecutable("git"), githubExecutable: try fake("gh-modern", version: "2.81.0", json: true))
    let report = await modern.scan(hosts: ["github.com", "ghe.example.invalid"])
    #expect(report.git.version != nil && report.gh.version == "2.81.0" && report.gh.meetsMinimum == true && report.structuredStatus)
    #expect(report.hosts.map(\.host) == ["github.com", "ghe.example.invalid"])
    #expect(report.hosts[0].effectiveAccount?.login == "octocat" && report.hosts[1].effectiveAccount == nil && report.hosts[1].usedByProjects)
    let legacy = SourceControlDiscovery(environment: environment, gitExecutable: nil, githubExecutable: try fake("gh-legacy", version: "2.40.0", json: false))
    let old = await legacy.scan(hosts: [])
    #expect(!old.git.isInstalled && old.gh.meetsMinimum == false && !old.structuredStatus)
    #expect(old.hosts.first?.effectiveAccount?.login == "legacy" && old.hosts.first?.effectiveAccount?.tokenSource == "oauth_token")
    let missing = await SourceControlDiscovery(environment: environment, gitExecutable: nil, githubExecutable: nil).scan(hosts: [])
    #expect(!missing.gh.isInstalled && missing.hosts.map(\.host) == ["github.com"] && missing.hosts[0].accounts.isEmpty)
    let commands = try String(contentsOf: log, encoding: .utf8)
    #expect(!commands.contains("--show-token") && !commands.contains("login") && !commands.contains("refresh"))
    #expect(commands.contains("auth status --json hosts") && commands.contains("auth status\n"))
}
