import XCTest
@testable import memanager

final class ProjectSemanticRelationshipToolTests: XCTestCase {
    func testFindRelatedFilesRanksTestPairAheadOfFolderSimilarity() async throws {
        let fixture = try ProjectToolTestFixture()

        let result = await fixture.execute(FindRelatedFilesTool(), arguments: ["path": "Sources/Conversation.swift"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("match 1:\npath: Tests/ConversationTests.swift"), result.content)
        XCTAssertTrue(result.content.contains("reason: test pair"), result.content)
    }

    func testFindTypeRelationshipsReportsDeclarationsExtensionsInheritanceAndConformers() async throws {
        let fixture = try ProjectToolTestFixture()

        let conversation = await fixture.execute(FindTypeRelationshipsTool(), arguments: ["name": "Conversation"])
        XCTAssertFalse(conversation.isError, conversation.content)
        XCTAssertTrue(conversation.content.contains("inherits from:\nNSObject"), conversation.content)
        XCTAssertTrue(conversation.content.contains("conforms to:\nRenderable"), conversation.content)
        XCTAssertTrue(conversation.content.contains("CustomStringConvertible"), conversation.content)
        XCTAssertTrue(conversation.content.contains("path: Sources/Conversation+Display.swift"), conversation.content)

        let renderable = await fixture.execute(FindTypeRelationshipsTool(), arguments: ["name": "Renderable"])
        XCTAssertFalse(renderable.isError, renderable.content)
        XCTAssertTrue(renderable.content.contains("relation: conforms"), renderable.content)
        XCTAssertTrue(renderable.content.contains("name: Conversation"), renderable.content)
    }

    func testSemanticToolsRespectExcludedSensitiveAndOversizedPolicies() async throws {
        let fixture = try ProjectToolTestFixture()
        fixture.config.maxFileSizeBytes = 1_024

        let excluded = await fixture.execute(FindSymbolTool(), arguments: ["name": "IgnoredThing"])
        XCTAssertFalse(excluded.isError, excluded.content)
        XCTAssertTrue(excluded.content.contains("(none)"), excluded.content)

        let sensitive = await fixture.execute(GetFileOutlineTool(), arguments: ["path": ".env"])
        XCTAssertTrue(sensitive.isError, sensitive.content)
        XCTAssertEqual(sensitive.content, "File denied by policy: secrets are not accessible.")

        let oversized = await fixture.execute(ReadFilesBatchTool(), arguments: [
            "files": [["path": "Sources/LargeSymbol.swift"]]
        ])
        XCTAssertFalse(oversized.isError, oversized.content)
        XCTAssertTrue(oversized.content.contains("status: error"), oversized.content)
        XCTAssertTrue(oversized.content.contains("File too large"), oversized.content)
    }
}
