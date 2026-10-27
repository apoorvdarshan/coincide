import Foundation
import Testing

@testable import CoincideKit

struct ChangeRequestCommandTests {
    @Test func eachHostUsesItsOwnCLI() {
        #expect(SourceControlKind.github.tool == .gh)
        #expect(SourceControlKind.unknown.tool == .gh)
        #expect(SourceControlKind.gitlab.tool == .glab)
        #expect(SourceControlKind.azureDevOps.tool == .az)
        #expect(SourceControlKind.forgejo.tool == .tea)
        #expect(SourceControlKind.bitbucket.tool == nil)
        #expect(SourceControlKind.gitcafe.tool == nil)
        #expect(ChangeRequestTool.gh.setupMessage == GitHubCLI.notReadyMessage)
    }

    @Test func gitLabCommands() {
        #expect(ChangeRequestCommands.glabAuthStatus(host: "gitlab.example.com:8443") == ["auth", "status", "--hostname", "gitlab.example.com:8443"])
        #expect(
            ChangeRequestCommands.glabOpenMergeRequests(branch: "feature/x")
                == ["mr", "list", "--source-branch", "feature/x", "--per-page", "20", "--output", "json"])
        // The title is a raw field, so one starting with `@` is never read from a file; the description is.
        #expect(
            ChangeRequestCommands.glabCreateMergeRequest(base: "main", head: "feature/x", title: "@notes: fix", bodyFile: "/tmp/body.md")
                == [
                    "api", "--method", "POST", "projects/:fullpath/merge_requests",
                    "--raw-field", "source_branch=feature/x", "--raw-field", "target_branch=main",
                    "--raw-field", "title=@notes: fix", "--field", "description=@/tmp/body.md",
                ])
        #expect(ChangeRequestCommands.glabProject == ["api", "projects/:fullpath"])
    }

    @Test func azureCommands() {
        #expect(
            ChangeRequestCommands.azOpenPullRequests(branch: "feature")
                == [
                    "repos", "pr", "list", "--detect", "true", "--source-branch", "feature", "--status", "active", "--top",
                    "20", "--only-show-errors", "--output", "json",
                ])
        #expect(
            ChangeRequestCommands.azCreatePullRequest(base: "main", head: "feature", titleFile: "/tmp/t", bodyFile: "/tmp/b")
                == [
                    "repos", "pr", "create", "--detect", "true", "--target-branch", "main", "--source-branch", "feature",
                    "--title", "@/tmp/t", "--description", "@/tmp/b", "--only-show-errors", "--output", "json",
                ])
        #expect(ChangeRequestCommands.azTakesLiterally("feature/x"))
        #expect(!ChangeRequestCommands.azTakesLiterally("x=@secrets"))
        // Never installs an extension or prompts.
        #expect(ChangeRequestTool.az.environment["AZURE_EXTENSION_USE_DYNAMIC_INSTALL"] == "no")
    }

    @Test func teaCommands() throws {
        #expect(
            ChangeRequestCommands.teaAPI(login: "codeberg", repository: "o/r", method: "POST", url: "https://x/api", hasBody: true)
                == ["api", "--include", "--login", "codeberg", "--repo", "o/r", "--method", "POST", "--data", "@-", "https://x/api"])
        #expect(
            ChangeRequestCommands.teaAPI(login: "l", repository: "o/r", method: "GET", url: "u", hasBody: false)
                == ["api", "--include", "--login", "l", "--repo", "o/r", "--method", "GET", "u"])

        let codeberg = TeaLogin(name: "codeberg", url: "https://codeberg.org/", sshHost: nil, user: "me", isDefault: true)
        #expect(
            ChangeRequestCommands.teaAPIURL(login: codeberg, repository: "owner/my repo", route: "pulls")
                == "https://codeberg.org/api/v1/repos/owner/my%20repo/pulls")
        let mounted = TeaLogin(name: "work", url: "https://git.example.com/gitea", sshHost: nil, user: "", isDefault: false)
        #expect(
            ChangeRequestCommands.teaAPIURL(login: mounted, repository: "o/r", route: nil)
                == "https://git.example.com/gitea/api/v1/repos/o/r")
        let ssh = TeaLogin(name: "ssh", url: "ssh://git@example.com", sshHost: nil, user: "", isDefault: false)
        #expect(ChangeRequestCommands.teaAPIURL(login: ssh, repository: "o/r", route: nil) == nil)
        #expect(
            ChangeRequestCommands.teaOpenPullRequestsRoute(branch: "feature/a b")
                == "pulls?state=open&head=feature%2Fa%20b&sort=recentupdate&limit=50&page=1")
    }
}

struct ChangeRequestJSONTests {
    private let gitlab = SourceControlHost.recognize(remoteURL: "git@gitlab.com:group/project.git")
    private let azure = SourceControlHost.recognize(remoteURL: "git@ssh.dev.azure.com:v3/org/project/repo")
    private let codeberg = SourceControlHost.recognize(remoteURL: "https://codeberg.org/owner/repo.git")

    @Test func readsGitLabMergeRequests() throws {
        let output = """
            [
              {"iid": 12, "title": "Add parser", "state": "opened", "source_branch": "feature/parser",
               "target_branch": "main", "web_url": "https://gitlab.com/group/project/-/merge_requests/12", "draft": true},
              {"iid": 13, "title": "Old", "state": "merged", "source_branch": "old", "target_branch": "main",
               "web_url": "javascript:alert(1)", "work_in_progress": false},
              {"iid": 14, "title": "Closed", "state": "closed", "source_branch": "c", "target_branch": "main"},
              {"iid": 15, "title": "Locked", "state": "locked", "source_branch": "l", "target_branch": "main", "work_in_progress": true},
              {"title": "No number"}
            ]
            """
        let requests = try #require(ChangeRequestJSON.gitLabMergeRequests(output, host: gitlab))
        #expect(requests.map(\.number) == [12, 13, 14, 15])
        #expect(
            requests[0]
                == GitPullRequest(
                    number: 12, url: "https://gitlab.com/group/project/-/merge_requests/12", title: "Add parser",
                    state: .open, baseBranch: "main", headBranch: "feature/parser", isDraft: true))
        #expect(requests[1].state == .merged)
        // A link that isn't a web page is replaced by the host's own.
        #expect(requests[1].url == "https://gitlab.com/group/project/-/merge_requests/13")
        #expect(requests[2].state == .closed && requests[2].url.hasSuffix("/merge_requests/14"))
        #expect(requests[3].state == .open && requests[3].isDraft)
        #expect(ChangeRequestJSON.gitLabMergeRequests("not json", host: gitlab) == nil)
        #expect(ChangeRequestJSON.gitLabMergeRequests("[]", host: gitlab) == [])

        let created = ChangeRequestJSON.gitLabMergeRequest(
            #"{"iid": 3, "title": "T", "state": "opened", "source_branch": "b", "target_branch": "main", "web_url": "https://gitlab.com/group/project/-/merge_requests/3"}"#,
            host: gitlab)
        #expect(created?.number == 3 && created?.headBranch == "b")
        #expect(ChangeRequestJSON.gitLabDefaultBranch(#"{"id": 1, "default_branch": "trunk"}"#) == "trunk")
        #expect(ChangeRequestJSON.gitLabDefaultBranch(#"{"default_branch": null}"#) == nil)
    }

    @Test func readsAzurePullRequests() throws {
        let output = """
            [
              {"pullRequestId": 7, "title": "Linked", "status": "active", "isDraft": true,
               "sourceRefName": "refs/heads/feature/x", "targetRefName": "refs/heads/main",
               "_links": {"web": {"href": "https://dev.azure.com/org/project/_git/repo/pullrequest/7"}}},
              {"pullRequestId": 8, "title": "Repository", "status": "completed",
               "sourceRefName": "refs/heads/a", "targetRefName": "refs/heads/main",
               "repository": {"name": "repo", "webUrl": "https://dev.azure.com/org/project/_git/repo/"}},
              {"pullRequestId": 9, "title": "REST only", "status": "abandoned",
               "sourceRefName": "refs/heads/b", "targetRefName": "refs/heads/main",
               "url": "https://dev.azure.com/org/1f2e/_apis/git/repositories/9a8b/pullRequests/9",
               "repository": {"name": "my repo", "project": {"name": "My Project"}}},
              {"pullRequestId": 10, "title": "Legacy", "status": "active",
               "sourceRefName": "refs/heads/c", "targetRefName": "refs/heads/main",
               "url": "https://org.visualstudio.com/_apis/git/repositories/9a8b/pullRequests/10",
               "repository": {"name": "repo", "project": {"name": "project"}}},
              {"pullRequestId": 11, "title": "Nothing", "status": "active",
               "sourceRefName": "refs/heads/d", "targetRefName": "refs/heads/main"}
            ]
            """
        let requests = try #require(ChangeRequestJSON.azurePullRequests(output, host: azure))
        #expect(requests.map(\.number) == [7, 8, 9, 10, 11])
        #expect(requests[0].headBranch == "feature/x" && requests[0].baseBranch == "main" && requests[0].isDraft)
        #expect(requests[0].url == "https://dev.azure.com/org/project/_git/repo/pullrequest/7")
        #expect(requests[1].state == .merged && requests[1].url == "https://dev.azure.com/org/project/_git/repo/pullrequest/8")
        #expect(requests[2].state == .closed)
        #expect(requests[2].url == "https://dev.azure.com/org/My%20Project/_git/my%20repo/pullrequest/9")
        #expect(requests[3].url == "https://org.visualstudio.com/project/_git/repo/pullrequest/10")
        // Without a link of its own, the page is found below the checkout's repository.
        #expect(requests[4].url == "https://dev.azure.com/org/project/_git/repo/pullrequest/11")
        #expect(ChangeRequestJSON.azureDefaultBranch(#"{"name": "repo", "defaultBranch": "refs/heads/develop"}"#) == "develop")
    }

    @Test func readsForgejoPullRequests() throws {
        let output = """
            [
              {"number": 3, "title": "Open", "html_url": "https://codeberg.org/owner/repo/pulls/3", "state": "open",
               "merged": false, "draft": false, "base": {"ref": "main", "sha": "a"}, "head": {"ref": "feature", "sha": "b"}},
              {"number": 4, "title": "WIP: later", "html_url": "https://codeberg.org/owner/repo/pulls/4", "state": "closed",
               "merged": true, "base": {"ref": "main"}, "head": {"ref": "later"}},
              {"number": 5, "title": "Closed", "state": "closed", "merged": false,
               "base": {"ref": "main"}, "head": {"ref": "gone"}}
            ]
            """
        let requests = try #require(ChangeRequestJSON.forgejoPullRequests(output, host: codeberg))
        #expect(requests[0] == GitPullRequest(
            number: 3, url: "https://codeberg.org/owner/repo/pulls/3", title: "Open", state: .open, baseBranch: "main",
            headBranch: "feature"))
        #expect(requests[1].state == .merged && requests[1].isDraft)
        #expect(requests[2].state == .closed && requests[2].url == "https://codeberg.org/owner/repo/pulls/5")
        #expect(ChangeRequestJSON.forgejoDefaultBranch(#"{"full_name": "owner/repo", "default_branch": "main"}"#) == "main")
    }

    @Test func readsTeaLoginsAndStatus() throws {
        let logins = try #require(
            ChangeRequestJSON.teaLogins(
                #"[{"name":"codeberg","url":"https://codeberg.org","ssh_host":"codeberg.org","user":"me","default":"true"},{"name":"work","url":"https://git.example.com","user":"me","default":false},{"url":"https://nameless"}]"#
            ))
        #expect(logins.map(\.name) == ["codeberg", "work"])
        #expect(logins[0].isDefault && !logins[1].isDefault && logins[0].sshHost == "codeberg.org")

        #expect(ChangeRequestJSON.teaHTTPStatus("HTTP/1.1 201 Created\nContent-Type: application/json\n") == 201)
        #expect(ChangeRequestJSON.teaHTTPStatus("HTTP/2 404\n") == 404)
        #expect(ChangeRequestJSON.teaHTTPStatus("") == nil)
    }

    @Test func keepsOnlyPlainWebLinks() {
        #expect(ChangeRequestJSON.httpURL("https://gitlab.com/g/p/-/merge_requests/1") != nil)
        #expect(ChangeRequestJSON.httpURL(" http://git.local/o/r/pulls/1 ") == "http://git.local/o/r/pulls/1")
        #expect(ChangeRequestJSON.httpURL("javascript:alert(1)") == nil)
        #expect(ChangeRequestJSON.httpURL("file:///etc/passwd") == nil)
        #expect(ChangeRequestJSON.httpURL("https://user:token@gitlab.com/x") == nil)
        #expect(ChangeRequestJSON.httpURL("") == nil)
    }
}

struct TeaLoginTests {
    private let codeberg = TeaLogin(name: "codeberg", url: "https://codeberg.org", sshHost: nil, user: "me", isDefault: false)
    private let ported = TeaLogin(name: "home", url: "https://git.example.com:3000", sshHost: nil, user: "me", isDefault: false)
    private let mounted = TeaLogin(name: "work", url: "https://git.example.com/gitea", sshHost: "work-git", user: "me", isDefault: false)

    private func remote(_ value: String) throws -> GitRemoteURL { try #require(GitRemoteURL.parse(value)) }

    @Test func matchesTheServerTheRemoteIsOn() throws {
        let logins = [codeberg, ported, mounted]
        #expect(TeaLogin.match(logins, remote: try remote("git@codeberg.org:owner/repo.git")) == codeberg)
        #expect(TeaLogin.match(logins, remote: try remote("https://codeberg.org/owner/repo.git")) == codeberg)
        #expect(TeaLogin.match(logins, remote: try remote("https://git.example.com:3000/o/r")) == ported)
        #expect(TeaLogin.match(logins, remote: try remote("https://git.example.com/gitea/o/r")) == mounted)
        #expect(TeaLogin.match(logins, remote: try remote("git@work-git:o/r")) == mounted)
        #expect(TeaLogin.match(logins, remote: try remote("https://elsewhere.org/o/r")) == nil)
    }

    @Test func severalLoginsForOneServerUseItsDefault() throws {
        var other = codeberg
        other.name = "codeberg-bot"
        let remote = try remote("https://codeberg.org/o/r")
        #expect(TeaLogin.match([codeberg, other], remote: remote) == nil)
        other.isDefault = true
        #expect(TeaLogin.match([codeberg, other], remote: remote) == other)
    }

    @Test func repositoryIsBelowTheMountPath() throws {
        #expect(mounted.repository(for: try remote("https://git.example.com/gitea/o/r.git")) == "o/r")
        #expect(codeberg.repository(for: try remote("git@codeberg.org:owner/repo.git")) == "owner/repo")
        #expect(codeberg.repository(for: try remote("https://codeberg.org/owner")) == nil)
    }
}

struct GitChangeRequestTermTests {
    private func status(branch: String? = "feature", changes: Bool = false, ahead: Int = 0, aheadOfDefault: Int = 0)
        -> GitStatus
    {
        GitStatus(
            isRepository: true, branch: branch, upstream: "origin/feature", ahead: ahead, aheadOfDefault: aheadOfDefault,
            hasRemote: true, files: changes ? [ChangedFile(path: "a", status: .modified)] : [])
    }

    @Test func gitLabActionsSayMergeRequest() {
        #expect(GitStackedAction.createPR.title(for: .mergeRequest) == "Create MR")
        #expect(GitStackedAction.commitPushPR.title(for: .mergeRequest) == "Commit, Push & Create MR")
        #expect(GitStackedAction.createPR.title(for: .pullRequest) == GitStackedAction.createPR.title)
        #expect(GitStackedAction.push.title(for: .mergeRequest) == "Push")

        let changes = GitQuickAction.resolve(status: status(changes: true), isBusy: false, hasOpenPullRequest: false, term: .mergeRequest)
        #expect(changes.kind == .run(.commitPushPR) && changes.title == "Commit, Push & Create MR")
        let ahead = GitQuickAction.resolve(status: status(ahead: 1), isBusy: false, hasOpenPullRequest: false, term: .mergeRequest)
        #expect(ahead.kind == .run(.createPR) && ahead.title == "Push & Create MR")
        let base = GitQuickAction.resolve(status: status(aheadOfDefault: 2), isBusy: false, hasOpenPullRequest: false, term: .mergeRequest)
        #expect(base.title == "Create MR")
        let detached = GitQuickAction.resolve(status: status(branch: nil), isBusy: false, hasOpenPullRequest: false, term: .mergeRequest)
        #expect(detached.kind == .hint("Check out a branch before pushing or opening a merge request."))
        // GitHub's words are unchanged.
        let github = GitQuickAction.resolve(status: status(changes: true), isBusy: false, hasOpenPullRequest: false)
        #expect(github.title == "Commit, Push & Create PR")
    }
}

/// The pull request flow against a remote named like each host, pushing to a local bare repository.
/// Host CLIs are turned off, so nothing reaches a real host and no pull request is ever created.
@MainActor
struct GitHostFlowTests {
    private let git: GitService = {
        let service = GitService(worktreesRoot: try! TestRepository.makeDirectory("worktrees"))
        service.hostToolsOverride = false
        return service
    }()

    /// A repository on `main` whose `origin` is `remote` for reading and a local bare repository for
    /// pushing, with `main` pushed and `feature/parser` checked out one commit ahead.
    private func repository(remote: String) async throws -> TestRepository {
        let repository = try await TestRepository.make()
        let bare = try TestRepository.makeDirectory("remote.git")
        try await repository.git(["init", "-q", "--bare", "-b", "main", bare.path], in: repository.url)
        try await repository.git("remote", "add", "origin", remote)
        try await repository.git("remote", "set-url", "--push", "origin", bare.path)
        try await repository.git("push", "-q", "-u", "origin", "main")
        try await repository.git("checkout", "-q", "-b", "feature/parser")
        try repository.write("parser.swift", "let parser = 1\n")
        try await repository.git("add", ".")
        try await repository.git("commit", "-q", "-m", "Add parser")
        return repository
    }

    @Test func readsTheHostOfTheBranchsRemote() async throws {
        let repository = try await repository(remote: "git@gitlab.com:group/project.git")
        let host = await git.sourceControlHost(repository.url, branch: "feature/parser")
        #expect(host?.kind == .gitlab && host?.repositoryURL?.absoluteString == "https://gitlab.com/group/project")

        let noRemote = try await TestRepository.make()
        #expect(await git.sourceControlHost(noRemote.url) == nil)
        let localRemote = try await TestRepository.make()
        try await localRemote.git("remote", "add", "origin", repository.url.path)
        #expect(await git.sourceControlHost(localRemote.url) == nil)
    }

    @Test func gitLabWithoutGlabOpensTheNewMergeRequestPage() async throws {
        let repository = try await repository(remote: "https://gitlab.com/group/project.git")
        let result = try await git.run(GitActionRequest(action: .createPR), in: repository.url)
        let page = try #require(
            URL(
                string:
                    "https://gitlab.com/group/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature%2Fparser&merge_request%5Btarget_branch%5D=main"
            ))
        #expect(result.push?.outcome == .pushed)
        #expect(result.pullRequest == nil && !result.pullRequestCreated)
        #expect(result.changeRequestPage == page)
        #expect(result.followUp == .openChangeRequestPage(page))
        #expect(result.host?.kind == .gitlab && result.changeRequestTerm == .mergeRequest)
        #expect(result.title == "Create the merge request on GitLab")
        #expect(result.detail?.hasPrefix("Pushed to origin/feature/parser") == true)
        #expect(await git.openPullRequest(for: "feature/parser", in: repository.url, refresh: true) == nil)
    }

    @Test func bitbucketOpensTheNewPullRequestPage() async throws {
        let repository = try await repository(remote: "git@bitbucket.org:ws/app.git")
        let result = try await git.run(GitActionRequest(action: .createPR), in: repository.url)
        #expect(
            result.followUp
                == .openChangeRequestPage(
                    URL(string: "https://bitbucket.org/ws/app/pull-requests/new?source=feature%2Fparser&dest=main&t=1")!))
        #expect(result.title == "Create the pull request on Bitbucket")
    }

    @Test func aPushOffersTheHostsWordForCreating() async throws {
        let repository = try await repository(remote: "https://gitlab.com/group/project.git")
        let result = try await git.run(GitActionRequest(action: .push), in: repository.url)
        #expect(result.followUp == .run(.createPR))
        #expect(result.changeRequestTerm == .mergeRequest)
    }

    @Test func gitHubStillNeedsGH() async throws {
        for remote in ["https://github.com/acme/app.git", "https://git.example.com/acme/app.git"] {
            let repository = try await repository(remote: remote)
            await #expect(throws: GitError(GitHubCLI.notReadyMessage)) {
                try await git.run(GitActionRequest(action: .createPR), in: repository.url)
            }
        }
    }
}
