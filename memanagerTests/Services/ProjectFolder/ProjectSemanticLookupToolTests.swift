import XCTest
@testable import memanager

final class ProjectSemanticLookupToolTests: XCTestCase {
    func testFindSymbolReturnsDeclarationsAndExtensions() async throws {
        let fixture = try ProjectToolTestFixture()

        let result = await fixture.execute(FindSymbolTool(), arguments: ["name": "Conversation"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("kind: class"), result.content)
        XCTAssertTrue(result.content.contains("path: Sources/Conversation.swift"), result.content)
        XCTAssertTrue(result.content.contains("kind: extension"), result.content)
        XCTAssertTrue(result.content.contains("path: Sources/Conversation+Display.swift"), result.content)
    }

    func testFindReferencesUsesTokenBoundaries() async throws {
        let fixture = try ProjectToolTestFixture()

        let result = await fixture.execute(FindReferencesTool(), arguments: ["symbol": "Mode"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("declarations:"), result.content)
        XCTAssertTrue(result.content.contains("path: Sources/Mode.swift"), result.content)
        XCTAssertTrue(result.content.contains("path: Sources/ModeStore.swift"), result.content)
        XCTAssertFalse(result.content.contains("snippet: struct ModeStore"), result.content)
    }

    func testGetFileOutlineIncludesImportsMarkersAndDeclarations() async throws {
        let fixture = try ProjectToolTestFixture()

        let result = await fixture.execute(GetFileOutlineTool(), arguments: ["path": "Sources/Conversation.swift"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("kind: import"), result.content)
        XCTAssertTrue(result.content.contains("summary: Foundation"), result.content)
        XCTAssertTrue(result.content.contains("kind: marker"), result.content)
        XCTAssertTrue(result.content.contains("summary: Conversation"), result.content)
        XCTAssertTrue(result.content.contains("kind: protocol"), result.content)
        XCTAssertTrue(result.content.contains("kind: class"), result.content)
    }

    func testReadFilesBatchPreservesOrderAndReportsInlineErrors() async throws {
        let fixture = try ProjectToolTestFixture()

        let result = await fixture.execute(ReadFilesBatchTool(), arguments: [
            "files": [
                ["path": "Sources/Conversation.swift", "offset": 0, "limit": 2],
                ["path": "Missing.swift", "offset": 0, "limit": 5],
                ["path": "Docs/Guide.md", "offset": 0, "limit": 2]
            ]
        ])

        XCTAssertFalse(result.isError, result.content)
        let firstIndex = try XCTUnwrap(result.content.range(of: "path: Sources/Conversation.swift")?.lowerBound)
        let secondIndex = try XCTUnwrap(result.content.range(of: "path: Missing.swift")?.lowerBound)
        let thirdIndex = try XCTUnwrap(result.content.range(of: "path: Docs/Guide.md")?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertLessThan(secondIndex, thirdIndex)
        XCTAssertTrue(result.content.contains("status: error"), result.content)
    }
}
