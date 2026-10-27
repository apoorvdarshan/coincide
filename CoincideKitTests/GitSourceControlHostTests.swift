import Foundation
import Testing

@testable import CoincideKit

struct GitRemoteURLTests {
    @Test func readsHTTPSAndSSHRemotes() throws {
        let https = try #require(GitRemoteURL.parse("https://github.com/apoorvdarshan/coincide.git"))
        #expect(https.transport == .https && https.hostname == "github.com" && https.port == nil)
        #expect(https.path == ["apoorvdarshan", "coincide"])
        #expect(https.host == "github.com")

        let scp = try #require(GitRemoteURL.parse("git@github.com:owner/repo.git"))
        #expect(scp.transport == .ssh && scp.hostname == "github.com" && scp.path == ["owner", "repo"])

        let userless = try #require(GitRemoteURL.parse("github.com:owner/repo"))
        #expect(userless.transport == .ssh && userless.hostname == "github.com" && userless.path == ["owner", "repo"])

        let ssh = try #require(GitRemoteURL.parse("ssh://git@gitlab.example.com:2222/group/sub/project.git"))
        #expect(ssh.transport == .ssh && ssh.port == 2222 && ssh.path == ["group", "sub", "project"])
        // An SSH port is not the web server's, so it is not part of the host.
        #expect(ssh.host == "gitlab.example.com")

        let git = try #require(GitRemoteURL.parse("git://git.example.com/owner/repo.git"))
        #expect(git.transport == .git && git.path == ["owner", "repo"])

        let gitSSH = try #require(GitRemoteURL.parse("git+ssh://git@example.com/owner/repo"))
        #expect(gitSSH.transport == .ssh)
    }

    @Test func keepsTheHTTPPortAndDropsCredentials() throws {
        let remote = try #require(GitRemoteURL.parse("https://user:s3cret@gitlab.example.com:8443/group/project/"))
        #expect(remote.hostname == "gitlab.example.com" && remote.port == 8443)
        #expect(remote.host == "gitlab.example.com:8443")
        #expect(remote.path == ["group", "project"])
        #expect(!String(describing: remote).contains("s3cret") && !String(describing: remote).contains("user"))
    }

    @Test func lowersTheHostButKeepsThePath() throws {
        let remote = try #require(GitRemoteURL.parse("  HTTPS://GitHub.COM/Owner/Repo.GIT?ref=x#top \n"))
        #expect(remote.hostname == "github.com")
        #expect(remote.path == ["Owner", "Repo"])
    }

    @Test func decodesEscapedPathSegments() throws {
        let remote = try #require(GitRemoteURL.parse("https://dev.azure.com/org/My%20Project/_git/repo"))
        #expect(remote.path == ["org", "My Project", "_git", "repo"])
    }

    @Test func readsBracketedIPv6Hosts() throws {
        let remote = try #require(GitRemoteURL.parse("https://[::1]:3000/owner/repo"))
        #expect(remote.hostname == "[::1]" && remote.port == 3000)
    }

    @Test(arguments: [
        "", "   ", "/Users/me/repo", "./repo", "../repo", "~/repo", "file:///tmp/repo.git", "C:/repo", "C:\\repo",
        "foo:bar", "https://", "https://host:99999/a/b", "https://host:12ab/a/b", "svn://example.com/a/b",
        "https://bad host/a/b", "-oProxyCommand=evil:a/b",
    ])
    func rejectsRemotesWithoutAHost(_ remote: String) {
        #expect(GitRemoteURL.parse(remote) == nil)
    }
}

struct SourceControlHostTests {
    private func host(_ remote: String) throws -> SourceControlHost {
        try #require(SourceControlHost.recognize(remoteURL: remote))
    }

    @Test func recognizesEachHost() throws {
        #expect(try host("https://github.com/o/r.git").kind == .github)
        #expect(try host("https://github.com/o/r.git").name == "GitHub")
        #expect(try host("git@github.example.com:o/r.git").name == "GitHub Self-Hosted")
        #expect(try host("https://acme.ghe.com/o/r").kind == .github)

        #expect(try host("git@gitlab.com:group/project.git").kind == .gitlab)
        #expect(try host("git@gitlab.com:group/project.git").name == "GitLab")
        #expect(try host("https://gitlab.example.com/group/project").name == "GitLab Self-Hosted")
        #expect(try host("https://code.gitlab.acme.io/group/project").kind == .gitlab)

        #expect(try host("git@bitbucket.org:ws/repo.git").kind == .bitbucket)
        #expect(try host("https://bitbucket.acme.com/scm/proj/repo.git").name == "Bitbucket Self-Hosted")

        #expect(try host("https://org@dev.azure.com/org/project/_git/repo").kind == .azureDevOps)
        #expect(try host("git@ssh.dev.azure.com:v3/org/project/repo").kind == .azureDevOps)
        #expect(try host("https://org.visualstudio.com/project/_git/repo").kind == .azureDevOps)
        #expect(try host("org@vs-ssh.visualstudio.com:v3/org/project/repo").kind == .azureDevOps)

        #expect(try host("https://codeberg.org/owner/repo.git").kind == .forgejo)
        #expect(try host("https://gitea.example.com/owner/repo").kind == .forgejo)
        #expect(try host("git@forgejo.example.org:owner/repo").kind == .forgejo)

        #expect(try host("git@git.cafe:owner/repo.git").kind == .gitcafe)
        #expect(try host("https://staging.git.cafe/owner/repo").kind == .gitcafe)
    }

    @Test func recognizesInT3CodesOrder() throws {
        // A name can carry several hosts' labels: Forgejo claims before GitHub, GitHub before GitLab.
        #expect(try host("https://gitea.github.example/o/r").kind == .forgejo)
        #expect(try host("https://gitlab.github.example/o/r").kind == .github)
        // Labels count, not substrings.
        #expect(try host("https://notgithub.com/o/r").kind == .unknown)
        #expect(try host("https://mygitlab.dev/o/r").kind == .unknown)
    }

    @Test func leavesOtherHostsUnknownAndLocalPathsAlone() throws {
        let unknown = try host("https://git.example.com:8443/team/app.git")
        #expect(unknown.kind == .unknown && unknown.name == "git.example.com:8443")
        #expect(unknown.displayName == "git.example.com")
        #expect(SourceControlHost.recognize(remoteURL: "/Users/me/remote.git") == nil)
    }

    @Test func namesHostsTheWayTheyCallThemselves() throws {
        #expect(try host("https://codeberg.org/o/r").displayName == "Codeberg")
        #expect(try host("https://gitea.example.com/o/r").displayName == "Gitea")
        #expect(try host("https://forgejo.example.org/o/r").displayName == "Forgejo")
        #expect(try host("https://gitlab.example.com/g/p").displayName == "GitLab")
        #expect(try host("https://dev.azure.com/o/p/_git/r").displayName == "Azure DevOps")
    }

    @Test func gitLabCallsThemMergeRequests() {
        for kind in SourceControlKind.allCases {
            #expect(kind.changeRequest == (kind == .gitlab ? .mergeRequest : .pullRequest))
        }
        #expect(ChangeRequestTerm.pullRequest.reference(12) == "#12")
        #expect(ChangeRequestTerm.mergeRequest.reference(12) == "!12")
        #expect(ChangeRequestTerm.mergeRequest.shortLabel == "MR")
        #expect(ChangeRequestTerm.pullRequest.title == "Pull Request")
    }

    // MARK: Web pages

    @Test func gitLabOpensItsNewMergeRequestPage() throws {
        let url = try host("git@gitlab.com:group/sub/project.git").newChangeRequestURL(base: "main", head: "feature/x")
        #expect(
            url?.absoluteString
                == "https://gitlab.com/group/sub/project/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature%2Fx&merge_request%5Btarget_branch%5D=main"
        )
    }

    @Test func bitbucketOpensItsNewPullRequestPage() throws {
        let cloud = try host("git@bitbucket.org:ws/repo.git").newChangeRequestURL(base: "main", head: "feature")
        #expect(cloud?.absoluteString == "https://bitbucket.org/ws/repo/pull-requests/new?source=feature&dest=main&t=1")

        let server = try host("https://bitbucket.acme.com/scm/PROJ/repo.git").newChangeRequestURL(base: "main", head: "feature")
        #expect(
            server?.absoluteString
                == "https://bitbucket.acme.com/projects/PROJ/repos/repo/pull-requests?create&sourceBranch=refs%2Fheads%2Ffeature&targetBranch=refs%2Fheads%2Fmain"
        )
        let serverSSH = try host("ssh://git@bitbucket.acme.com:7999/proj/repo.git")
        #expect(serverSSH.repositoryURL?.absoluteString == "https://bitbucket.acme.com/projects/proj/repos/repo")
        let personal = try host("ssh://git@bitbucket.acme.com:7999/~me/repo.git")
        #expect(personal.repositoryURL?.absoluteString == "https://bitbucket.acme.com/users/me/repos/repo")
    }

    @Test func azureUsesTheWebSpellingOfSSHRemotes() throws {
        let ssh = try host("git@ssh.dev.azure.com:v3/org/My%20Project/repo")
        #expect(ssh.repositoryURL?.absoluteString == "https://dev.azure.com/org/My%20Project/_git/repo")
        #expect(
            ssh.newChangeRequestURL(base: "main", head: "feature")?.absoluteString
                == "https://dev.azure.com/org/My%20Project/_git/repo/pullrequestcreate?sourceRef=feature&targetRef=main")

        let https = try host("https://org@dev.azure.com/org/project/_git/repo")
        #expect(https.repositoryURL?.absoluteString == "https://dev.azure.com/org/project/_git/repo")

        let legacy = try host("org@vs-ssh.visualstudio.com:v3/Org/project/repo")
        #expect(legacy.repositoryURL?.absoluteString == "https://org.visualstudio.com/project/_git/repo")

        let collection = try host("https://org.visualstudio.com/DefaultCollection/project/_git/repo")
        #expect(collection.repositoryURL?.absoluteString == "https://org.visualstudio.com/DefaultCollection/project/_git/repo")

        // Not a repository path Azure serves.
        #expect(try host("https://dev.azure.com/org/project").repositoryURL == nil)
    }

    @Test func forgejoAndGitHubOpenTheirComparePages() throws {
        let codeberg = try host("https://codeberg.org/owner/repo.git")
        #expect(
            codeberg.newChangeRequestURL(base: "main", head: "feature/x")?.absoluteString
                == "https://codeberg.org/owner/repo/compare/main...feature/x")
        // A server mounted below a path keeps it.
        let mounted = try host("https://gitea.example.com/git/owner/repo")
        #expect(mounted.repositoryURL?.absoluteString == "https://gitea.example.com/git/owner/repo")

        let github = try host("https://github.com/o/r")
        #expect(
            github.newChangeRequestURL(base: "main", head: "fix")?.absoluteString
                == "https://github.com/o/r/compare/main...fix?expand=1")
    }

    @Test func gitCafeAndUnknownHostsHaveNoCreatePage() throws {
        let cafe = try host("git@git.cafe:owner/repo.git")
        #expect(cafe.newChangeRequestURL(base: "main", head: "x") == nil)
        #expect(cafe.repositoryURL?.absoluteString == "https://git.cafe/owner/repo")
        let unknown = try host("https://git.example.com/o/r")
        #expect(unknown.newChangeRequestURL(base: "main", head: "x") == nil)
        #expect(unknown.changeRequestURL(number: 1) == nil)
    }

    @Test func webPagesAreAlwaysHTTPS() throws {
        // An SSH port is dropped; an HTTPS port is kept; a plain HTTP host is asked for over HTTPS.
        #expect(try host("ssh://git@gitlab.example.com:2222/team/app.git").webOrigin?.absoluteString == "https://gitlab.example.com")
        #expect(try host("https://gitlab.example.com:8443/team/app.git").webOrigin?.absoluteString == "https://gitlab.example.com:8443")
        #expect(try host("https://gitlab.example.com:443/team/app.git").webOrigin?.absoluteString == "https://gitlab.example.com")
        #expect(try host("http://gitlab.example.com/team/app.git").webOrigin?.absoluteString == "https://gitlab.example.com")
        // An HTTP server on a port of its own has no HTTPS address Coincide can name.
        let plain = try host("http://gitlab.example.com:8080/team/app.git")
        #expect(plain.webOrigin == nil && plain.repositoryURL == nil)
        #expect(plain.newChangeRequestURL(base: "main", head: "x") == nil)
        // SSH aliases and IPv6 literals are not web host names.
        #expect(try host("git@gitlab_work:team/app.git").webOrigin == nil)
        #expect(try host("https://[::1]:3000/owner/repo").webOrigin == nil)
    }

    @Test func pagesNeverCarryCredentials() throws {
        let url = try host("https://oauth2:not-a-real-password@gitlab.com/group/project.git")
            .newChangeRequestURL(base: "main", head: "feature")
        let text = try #require(url?.absoluteString)
        #expect(!text.contains("password") && !text.contains("oauth2") && !text.contains("@"))
    }

    @Test func branchNamesAreEscaped() throws {
        let gitlab = try host("https://gitlab.com/g/p").newChangeRequestURL(base: "main", head: "fix/a b#c?d&e=f")
        #expect(gitlab?.absoluteString.hasSuffix("source_branch%5D=fix%2Fa%20b%23c%3Fd%26e%3Df&merge_request%5Btarget_branch%5D=main") == true)
        #expect(gitlab?.absoluteString.contains("#") == false && gitlab?.fragment == nil)

        let forgejo = try host("https://codeberg.org/o/r").newChangeRequestURL(base: "main", head: "fix/a b#c?d")
        #expect(forgejo?.absoluteString == "https://codeberg.org/o/r/compare/main...fix/a%20b%23c%3Fd")
        #expect(forgejo?.fragment == nil)
    }

    @Test func refusesPathsThatLeaveTheRepository() throws {
        #expect(try host("https://gitlab.com/group/%2E%2E/project").repositoryURL == nil)
        #expect(try host("https://gitlab.com/g/p").newChangeRequestURL(base: "../../admin", head: "x") == nil)
        #expect(try host("https://gitlab.com/g/p").newChangeRequestURL(base: "main", head: "") == nil)
        // GitHub repositories are exactly owner/name.
        #expect(try host("https://github.com/o/r/extra").repositoryURL == nil)
    }

    @Test func linksChangeRequestsByNumber() throws {
        #expect(try host("https://github.com/o/r").changeRequestURL(number: 5)?.absoluteString == "https://github.com/o/r/pull/5")
        #expect(
            try host("https://gitlab.com/g/p").changeRequestURL(number: 5)?.absoluteString
                == "https://gitlab.com/g/p/-/merge_requests/5")
        #expect(
            try host("https://bitbucket.org/w/r").changeRequestURL(number: 5)?.absoluteString
                == "https://bitbucket.org/w/r/pull-requests/5")
        #expect(
            try host("https://dev.azure.com/o/p/_git/r").changeRequestURL(number: 5)?.absoluteString
                == "https://dev.azure.com/o/p/_git/r/pullrequest/5")
        #expect(try host("https://codeberg.org/o/r").changeRequestURL(number: 5)?.absoluteString == "https://codeberg.org/o/r/pulls/5")
        #expect(try host("https://github.com/o/r").changeRequestURL(number: 0) == nil)
    }
}

struct ChangeRequestLinkTests {
    @Test func readsEachHostsRoute() throws {
        let github = try #require(ChangeRequestLink.parse("https://github.com/Owner/Repo/pull/12/files"))
        #expect(github == ChangeRequestLink(kind: .github, host: "github.com", repository: "owner/repo", number: 12))

        let gitlab = try #require(ChangeRequestLink.parse("https://gitlab.com/group/sub/project/-/merge_requests/7/diffs"))
        #expect(gitlab.kind == .gitlab && gitlab.repository == "group/sub/project" && gitlab.number == 7)

        let forgejo = try #require(ChangeRequestLink.parse("https://codeberg.org/owner/repo/pulls/3"))
        #expect(forgejo.kind == .forgejo && forgejo.repository == "owner/repo")

        let cafe = try #require(ChangeRequestLink.parse("https://git.cafe/owner/repo/pulls/9"))
        #expect(cafe.kind == .gitcafe && cafe.number == 9)

        let bitbucket = try #require(ChangeRequestLink.parse("https://bitbucket.org/ws/repo/pull-requests/4"))
        #expect(bitbucket.kind == .bitbucket)

        let azure = try #require(ChangeRequestLink.parse("https://dev.azure.com/org/project/_git/repo/pullrequest/5"))
        #expect(azure.kind == .azureDevOps && azure.repository == "org/project/_git/repo" && azure.number == 5)
    }

    @Test(arguments: [
        "https://github.com/o/r/issues/12", "https://github.com/o/r/pull/0", "https://github.com/o/r/pull/abc",
        "ftp://github.com/o/r/pull/1", "not a url", "https://example.com/pull-requests/4",
        "https://example.com/o/r/pull-requests/4",
    ])
    func ignoresOtherPages(_ url: String) {
        #expect(ChangeRequestLink.parse(url) == nil)
    }
}
