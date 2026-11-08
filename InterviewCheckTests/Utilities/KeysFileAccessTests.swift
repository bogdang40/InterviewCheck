import XCTest
@testable import InterviewCheck

final class KeysFileAccessTests: XCTestCase {
    func testOwnerOnlyModesPassTheGate() {
        XCTAssertTrue(KeysFileAccess.isPermissionSafe(mode: 0o600))
        XCTAssertTrue(KeysFileAccess.isPermissionSafe(mode: 0o700))
        XCTAssertTrue(KeysFileAccess.isPermissionSafe(mode: 0o400))
    }

    func testGroupOrWorldReadableModesAreRefused() {
        XCTAssertFalse(KeysFileAccess.isPermissionSafe(mode: 0o644), "World readable must be refused")
        XCTAssertFalse(KeysFileAccess.isPermissionSafe(mode: 0o640), "Group readable must be refused")
        XCTAssertFalse(KeysFileAccess.isPermissionSafe(mode: 0o604))
        XCTAssertFalse(KeysFileAccess.isPermissionSafe(mode: 0o444))
    }

    func testParsesValueSkippingCommentsAndWhitespace() {
        let contents = """
        # developer keys
        INTERVIEWCHECK_CLAUDE_API_KEY = sk-claude-123

        INTERVIEWCHECK_OPENAI_API_KEY=sk-openai-456
        NOT_A_KEY_LINE
        """

        XCTAssertEqual(KeysFileAccess.value(for: "INTERVIEWCHECK_CLAUDE_API_KEY", contents: contents), "sk-claude-123")
        XCTAssertEqual(KeysFileAccess.value(for: "INTERVIEWCHECK_OPENAI_API_KEY", contents: contents), "sk-openai-456")
        XCTAssertNil(KeysFileAccess.value(for: "INTERVIEWCHECK_AZURE_API_KEY", contents: contents))
    }

    func testCommentedOutKeyIsNotParsed() {
        let contents = "# INTERVIEWCHECK_OPENAI_API_KEY=sk-disabled"

        XCTAssertNil(KeysFileAccess.value(for: "INTERVIEWCHECK_OPENAI_API_KEY", contents: contents))
    }
}
