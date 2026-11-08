import XCTest
@testable import memanager

final class SearchAndGlobRipgrepTests: XCTestCase {
    private var fixture: ProjectToolTestFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(RipgrepBinaryLocator.shared.locate() == nil, "ripgrep not installed")
        fixture = try ProjectToolTestFixture()
        fixture.config = ProjectFolderConfig(
            isEnabled: true,
            bookmarkData: nil,
            displayPath: fixture.rootURL.path,
            rootName: fixture.rootURL.lastPathComponent,
            maxFileSizeBytes: 50 * 1024 * 1024,
            maxSearchResults: 200,
            maxToolIterations: 10,
            allowSensitiveReads: false
        )
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func testSearchReturnsContextLinesInOutput() async {
        let tool = SearchFilesTool()
        let result = await fixture.execute(tool, arguments: [
            "pattern": "Conversation",
            "contextBefore": 1,
            "contextAfter": 1
        ])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Conversation"))
        let lines = result.content.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 3)
    }

    func testSearchFixedStringsDisablesRegex() async {
        let tool = SearchFilesTool()
        let result = await fixture.execute(tool, arguments: [
            "pattern": "greet(",
            "fixedStrings": true
        ])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("greet("))
    }

    func testSearchSkipsSensitivePathsByDefault() async {
        let tool = SearchFilesTool()
        let result = await fixture.execute(tool, arguments: ["pattern": "secret-value"])
        XCTAssertFalse(result.content.contains(".env"))
    }

    func testScopedSearchReturnsPathsRelativeToSelectedRoot() async {
        let result = await fixture.execute(SearchFilesTool(), arguments: [
            "pattern": "Conversation", "path": "Sources"
        ])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Sources/Conversation.swift:"))
        XCTAssertFalse(result.content.contains("Tests/"))
    }

    func testSearchCapsMatchesAcrossFiles() async {
        fixture.config.maxSearchResults = 2
        let result = await fixture.execute(SearchFilesTool(), arguments: ["pattern": "Conversation"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.contentTruncated)
        let matches = result.content.split(separator: "\n").filter { !$0.hasPrefix("(truncated") }
        XCTAssertEqual(matches.count, 2)
    }

    func testGlobReturnsFilteredByFileType() async {
        let tool = GlobTool()
        let result = await fixture.execute(tool, arguments: [
            "pattern": "**/*.swift",
            "fileTypes": ["swift"]
        ])
        XCTAssertFalse(result.isError, "tool errored: \(result.content)")
        let paths = result.content.split(separator: "\n").map(String.init)
        XCTAssertFalse(paths.isEmpty, "empty paths; raw content=\(result.content)")
        for path in paths where !path.contains("truncated") {
            XCTAssertTrue(path.hasSuffix(".swift"), "non swift path leaked: '\(path)'; full content=\(result.content)")
        }
    }

    func testGlobSortsNewestFirst() async throws {
        let url = fixture.rootURL.appendingPathComponent("Sources/Conversation.swift")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        let tool = GlobTool()
        let result = await fixture.execute(tool, arguments: [
            "pattern": "**/*.swift"
        ])
        XCTAssertFalse(result.isError, "tool errored: \(result.content)")
        let first = result.content.split(separator: "\n").first.map(String.init)
        XCTAssertEqual(first, "Sources/Conversation.swift", "first path was \(first ?? "nil"); full content: \(result.content)")
    }
}
