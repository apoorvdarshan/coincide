import Foundation
import Testing

@testable import CoincideKit

struct GitCLITests {
    @Test func cappedReadsKeepAtMostTheLimit() async throws {
        let repository = try await TestRepository.make()
        let chunk = "0123456789"
        try repository.write("big.txt", String(repeating: chunk, count: 200_000))
        try await repository.git("add", "big.txt")
        try await repository.git("commit", "-q", "-m", "big")

        let capped = await GitCLI.git(["show", "HEAD:big.txt"], in: repository.url, maxOutputBytes: 1_000)
        #expect(capped.truncated)
        #expect(capped.result.succeeded)
        #expect(capped.result.stdout == String(repeating: chunk, count: 100))

        // Output that exactly fits is not cut.
        let exact = await GitCLI.git(["show", "HEAD:README.md"], in: repository.url, maxOutputBytes: 6)
        #expect(!exact.truncated && exact.result.succeeded && exact.result.stdout == "hello\n")

        let failed = await GitCLI.git(["show", "HEAD:missing.txt"], in: repository.url, maxOutputBytes: 1_000)
        #expect(!failed.truncated && !failed.result.succeeded && !failed.result.stderr.isEmpty)
    }

    @Test func aMissingGitReadsAsNoRepository() async {
        #expect(GitCLI.isNotRepository(GitCLI.gitMissingMessage))
        let missing = ProcessRunner.Result(status: 127, stdout: "", stderr: GitCLI.gitMissingMessage)
        #expect(GitError.failed("Could not commit.", missing).detail == GitCLI.gitMissingMessage)
        // This machine has git, so it is found.
        #expect(await GitService.gitExecutable() != nil)
    }
}
