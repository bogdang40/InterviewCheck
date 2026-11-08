import XCTest
@testable import memanager

final class ReadFileToolV2Tests: XCTestCase {
    private var fixture: ProjectToolTestFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
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

    func testReadSliceWithOffsetAndLimit() throws {
        let lines = (1...50).map { "line \($0)" }.joined(separator: "\n")
        try writeFile("Sources/numbered.txt", text: lines)
        let service = ProjectTextReadServiceV2(context: fixture.context())
        let result = try service.read(
            path: "Sources/numbered.txt",
            offset: 10,
            limit: 5,
            byteBudget: 256 * 1024
        )
        XCTAssertEqual(result.kind, .utf8Text)
        XCTAssertEqual(result.lines.count, 5)
        XCTAssertEqual(result.startLine, 10)
        XCTAssertEqual(result.endLine, 14)
        XCTAssertEqual(result.lines.first, "line 10")
        XCTAssertTrue(result.more)
    }

    func testByteBudgetStopsEmission() throws {
        let fatLine = String(repeating: "x", count: 500)
        let bigFile = (1...20).map { "\($0) " + fatLine }.joined(separator: "\n")
        try writeFile("Sources/big.txt", text: bigFile)
        let service = ProjectTextReadServiceV2(context: fixture.context())
        let result = try service.read(
            path: "Sources/big.txt",
            offset: 1,
            limit: 20,
            byteBudget: 2_000
        )
        XCTAssertTrue(result.cut, "expected byte budget to trip cut")
        XCTAssertTrue(result.more)
        XCTAssertLessThan(result.lines.count, 20)
    }

    func testReadImagePayload() throws {
        try writePNG("Assets/dot.png")
        let service = ProjectTextReadServiceV2(context: fixture.context())
        let result = try service.read(
            path: "Assets/dot.png",
            offset: 1,
            limit: 10,
            byteBudget: 256 * 1024
        )
        if case .image(let mime) = result.kind {
            XCTAssertEqual(mime, "image/png")
        } else {
            XCTFail("expected image kind, got \(result.kind)")
        }
        XCTAssertNotNil(result.imageBase64)
        XCTAssertGreaterThan(result.byteSize, 0)
    }

    func testBinaryFileRejected() throws {
        let bytes = Data([0x00, 0x01, 0x02, 0x00, 0x03, 0x04])
        let url = fixture.rootURL.appendingPathComponent("Assets/blob.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let service = ProjectTextReadServiceV2(context: fixture.context())
        XCTAssertThrowsError(try service.read(
            path: "Assets/blob.bin",
            offset: 1,
            limit: 10,
            byteBudget: 4096
        ))
    }

    func testReadFileToolSurface() async throws {
        let lines = (1...5).map { "row \($0)" }.joined(separator: "\n")
        try writeFile("Sources/tool.txt", text: lines)
        let tool = ReadFileTool()
        let result = await fixture.execute(tool, arguments: ["path": "Sources/tool.txt"])
        XCTAssertFalse(result.contentTruncated)
        XCTAssertTrue(result.content.contains("row 1"))
        XCTAssertTrue(result.content.contains("row 5"))
    }

    // Helpers

    private func writeFile(_ relative: String, text: String) throws {
        let url = fixture.rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePNG(_ relative: String) throws {
        let url = fixture.rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54,
            0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05,
            0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
            0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
            0xAE, 0x42, 0x60, 0x82
        ]
        try Data(bytes).write(to: url)
    }
}
