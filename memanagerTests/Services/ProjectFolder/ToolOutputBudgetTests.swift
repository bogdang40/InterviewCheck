import XCTest
@testable import memanager

final class ToolOutputBudgetTests: XCTestCase {
    private var tempRoot: URL!
    private var cache: ToolOutputCacheDir!
    private var budget: ToolOutputBudget!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolOutputBudgetTests-\(UUID().uuidString)", isDirectory: true)
        cache = ToolOutputCacheDir(baseURL: tempRoot, maxFiles: 3)
        budget = ToolOutputBudget(cache: cache)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testSmallContentPassesThrough() {
        let outcome = budget.apply("tiny")
        XCTAssertFalse(outcome.truncated)
        XCTAssertEqual(outcome.content, "tiny")
        XCTAssertNil(outcome.overflowPath)
    }

    func testOversizedContentIsTruncatedAndSpilled() throws {
        let oneKB = String(repeating: "x", count: 1024)
        let big = (1...200).map { "\($0) \(oneKB)" }.joined(separator: "\n")
        let outcome = budget.apply(big, limits: .init(maxLines: 500, maxBytes: 16 * 1024))
        XCTAssertTrue(outcome.truncated)
        XCTAssertLessThan(outcome.content.utf8.count, 20 * 1024)
        XCTAssertTrue(outcome.content.contains("full output saved to"))
        XCTAssertNotNil(outcome.overflowPath)
        let spilled = try String(contentsOfFile: outcome.overflowPath!, encoding: .utf8)
        XCTAssertEqual(spilled, big)
    }

    func testLineLimitAlsoTriggersTruncation() {
        let many = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let outcome = budget.apply(many, limits: .init(maxLines: 100, maxBytes: 1024 * 1024))
        XCTAssertTrue(outcome.truncated)
        let previewLines = outcome.content.split(separator: "\n").dropLast()
        XCTAssertEqual(previewLines.count, 100)
    }
}
