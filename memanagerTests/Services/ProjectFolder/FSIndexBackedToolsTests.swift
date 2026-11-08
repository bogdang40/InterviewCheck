import XCTest
@testable import memanager

final class FSIndexBackedToolsTests: XCTestCase {
    private var root: URL!
    private var config: ProjectFolderConfig!
    private var index: FSIndexActor!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipIf(RipgrepBinaryLocator.shared.locate() == nil, "ripgrep not installed")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSIndexBackedToolsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("swift a", to: "Sources/A.swift")
        try writeText("swift b", to: "Sources/Inner/B.swift")
        try writeText("md", to: "Docs/ReadMe.md")
        try writeText("build/\n", to: ".gitignore")
        try writeText("built", to: "build/artifact.txt")
        config = ProjectFolderConfig(
            isEnabled: true,
            bookmarkData: nil,
            displayPath: root.path,
            rootName: root.lastPathComponent,
            maxFileSizeBytes: 10 * 1024 * 1024,
            maxSearchResults: 200,
            maxToolIterations: 10,
            allowSensitiveReads: false
        )
        index = FSIndexActor()
        try await index.warm(root: root)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        index = nil
        try await super.tearDown()
    }

    private func context() -> ProjectToolContext {
        ProjectToolContext(rootURL: root, config: config, access: .shared, fileTime: nil, fsIndex: index)
    }

    func testListDirectoryReadsIndexAndShowsSubdirectoryFirst() async {
        let tool = ListDirectoryTool()
        let result = await tool.execute(callID: "t", arguments: ["path": ""], context: context())
        XCTAssertFalse(result.isError)
        let lines = result.content.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("Sources/"))
        XCTAssertTrue(lines.contains("Docs/"))
        let sourcesIndex = lines.firstIndex(of: "Sources/") ?? -1
        let docsIndex = lines.firstIndex(of: "Docs/") ?? -1
        XCTAssertLessThan(docsIndex, sourcesIndex + 2, "subdirectories should appear before files in the listing")
    }

    func testListDirectoryOmitsIgnoredEntriesByDefault() async {
        let tool = ListDirectoryTool()
        let result = await tool.execute(callID: "t", arguments: ["path": ""], context: context())
        XCTAssertFalse(result.content.contains("build/"))
    }

    func testFileInfoReportsIgnoredFlag() async {
        let tool = FileInfoTool()
        let result = await tool.execute(callID: "t", arguments: ["path": "build/artifact.txt"], context: context())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("ignored: true"))
    }

    func testFileInfoReportsLanguageKind() async {
        let tool = FileInfoTool()
        let result = await tool.execute(callID: "t", arguments: ["path": "Sources/A.swift"], context: context())
        XCTAssertTrue(result.content.contains("language: swift"))
        XCTAssertTrue(result.content.contains("ignored: false"))
    }

    func testGlobReturnsSamePathsWithWarmIndex() async {
        let tool = GlobTool()
        let result = await tool.execute(callID: "t", arguments: ["pattern": "**/*.swift"], context: context())
        let paths = result.content.split(separator: "\n").map(String.init)
        XCTAssertEqual(Set(paths), ["Sources/A.swift", "Sources/Inner/B.swift"])
    }

    func testGlobScopesPathsAndMatchesFileTypesWithWarmIndex() async throws {
        try writeText("fn main() {}", to: "Sources/tool.rs")
        try writeText("fn main() {}", to: "Docs/other.rs")
        let result = await GlobTool().execute(
            callID: "t",
            arguments: ["path": "Sources", "pattern": "*.rs", "fileTypes": ["rust"]],
            context: context()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.content, "Sources/tool.rs")
    }

    func testGlobIncludesHiddenFilesWhenRequestedWithWarmIndex() async throws {
        try writeText("hidden", to: "Sources/.draft.md")
        await index.invalidate(paths: ["Sources/.draft.md"], root: root)
        let result = await GlobTool().execute(
            callID: "t",
            arguments: ["pattern": "*.md", "includeHidden": true],
            context: context()
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("Sources/.draft.md"))
    }

    func testGetStructureWalksIndex() async {
        let tool = GetStructureTool()
        let result = await tool.execute(callID: "t", arguments: ["path": "", "depth": 3], context: context())
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Sources/"))
        XCTAssertTrue(result.content.contains("A.swift"))
        XCTAssertTrue(result.content.contains("Inner/"))
        XCTAssertTrue(result.content.contains("B.swift"))
    }

    private func writeText(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
