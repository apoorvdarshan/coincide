import Foundation
import Testing

@testable import CoincideKit

struct GitCLITests {
    @Test func aMissingGitReadsAsNoRepository() async {
        #expect(GitCLI.isNotRepository(GitCLI.gitMissingMessage))
        let missing = ProcessRunner.Result(status: 127, stdout: "", stderr: GitCLI.gitMissingMessage)
        #expect(GitError.failed("Could not commit.", missing).detail == GitCLI.gitMissingMessage)
        // This machine has git, so it is found.
        #expect(await GitService.gitExecutable() != nil)
    }
}
