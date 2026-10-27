import Foundation

/// Pull requests through the GitHub CLI (`gh`), using the user's own sign-in.
enum GitHubCLI {
    private static let pullRequestFields = "number,url,title,state,baseRefName,headRefName,isDraft"

    static var notReadyMessage: String {
        String(localized: "Install the GitHub CLI (gh) and run “gh auth login” to create pull requests.")
    }

    @concurrent static func isReady(_ cwd: URL) async -> Bool {
        await GitCLI.gh(["auth", "status"], in: cwd, timeout: 20)?.succeeded ?? false
    }

    /// The most recent pull request whose head is `branch`, in `state` (`open` or `all`).
    @concurrent static func pullRequest(for branch: String, in cwd: URL, state: String) async -> GitPullRequest? {
        guard
            let result = await GitCLI.gh(
                [
                    "pr", "list", "--head", branch, "--state", state, "--limit", "1", "--json", pullRequestFields,
                ], in: cwd),
            result.succeeded
        else { return nil }
        return (try? JSONDecoder().decode([GitPullRequest].self, from: Data(result.stdout.utf8)))?.first
    }

    @concurrent static func pullRequest(url: String, in cwd: URL) async -> GitPullRequest? {
        guard let result = await GitCLI.gh(["pr", "view", url, "--json", pullRequestFields], in: cwd), result.succeeded
        else { return nil }
        return try? JSONDecoder().decode(GitPullRequest.self, from: Data(result.stdout.utf8))
    }

    /// The repository's default branch as GitHub knows it.
    @concurrent static func defaultBranch(_ cwd: URL) async -> String? {
        guard
            let result = await GitCLI.gh(
                ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], in: cwd, timeout: 20),
            result.succeeded
        else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    @concurrent static func createPullRequest(
        title: String, body: String, base: String, head: String, in cwd: URL
    ) async throws -> GitPullRequest {
        guard await GitCLI.ghExecutable() != nil else { throw GitError(notReadyMessage) }
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("coincide-pr-body-\(UUID().uuidString).md")
        try body.write(to: bodyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        guard
            let result = await GitCLI.gh(
                ["pr", "create", "--base", base, "--head", head, "--title", title, "--body-file", bodyFile.path], in: cwd,
                timeout: 120)
        else { throw GitError(notReadyMessage) }
        guard result.succeeded else {
            throw GitError.failed(String(localized: "Could not create the pull request."), result)
        }
        let url = result.stdout.split(whereSeparator: \.isNewline).last { $0.hasPrefix("http") }.map(String.init)
        if let url, let created = await pullRequest(url: url, in: cwd) { return created }
        if let created = await pullRequest(for: head, in: cwd, state: "open") { return created }
        let number = url.flatMap { Int($0.split(separator: "/").last ?? "") } ?? 0
        return GitPullRequest(
            number: number, url: url ?? "", title: title, state: .open, baseBranch: base, headBranch: head)
    }
}
