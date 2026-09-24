import XCTest
@testable import GooseKit

final class GitRepositoryInfoTests: XCTestCase {
    func testParseDistinguishesLinkedWorktreeAndBranch() throws {
        let output = "/Users/me/project/wt\n/Users/me/project/.git/worktrees/wt\n/Users/me/project/.git\nfeature/ui\n"
        let info = try XCTUnwrap(GooseService.GitRepositoryInfo.parse(output))
        XCTAssertEqual(info.repositoryName, "project")
        XCTAssertEqual(info.branch, "feature/ui")
        XCTAssertTrue(info.isWorktree)
    }

    func testParseRejectsMissingGitMetadata() {
        XCTAssertNil(GooseService.GitRepositoryInfo.parse("not-a-git-directory\n"))
    }
}
