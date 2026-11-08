import XCTest
@testable import memanager

final class FileTimeRegistryTests: XCTestCase {
    func testNeverReadIsReportedBeforeRecord() async {
        let registry = FileTimeRegistry()
        let outcome = await registry.assertState(
            path: "foo.txt",
            current: .init(mtime: Date(), size: 1)
        )
        XCTAssertEqual(outcome, .neverRead)
    }

    func testUnchangedWhenStampIdentical() async {
        let registry = FileTimeRegistry()
        let stamp = FileTimeRegistry.Stamp(mtime: Date(timeIntervalSince1970: 1_000_000), size: 42)
        await registry.record(path: "foo.txt", stamp: stamp)
        let outcome = await registry.assertState(path: "foo.txt", current: stamp)
        XCTAssertEqual(outcome, .unchanged)
    }

    func testDriftedWhenMTimeChanges() async {
        let registry = FileTimeRegistry()
        let priorStamp = FileTimeRegistry.Stamp(mtime: Date(timeIntervalSince1970: 1_000_000), size: 42)
        await registry.record(path: "foo.txt", stamp: priorStamp)
        let current = FileTimeRegistry.Stamp(mtime: Date(timeIntervalSince1970: 2_000_000), size: 42)
        let outcome = await registry.assertState(path: "foo.txt", current: current)
        XCTAssertEqual(outcome, .driftedSince(priorStamp))
    }

    func testClearResetsRegistry() async {
        let registry = FileTimeRegistry()
        await registry.record(path: "foo", stamp: .init(mtime: Date(), size: 1))
        await registry.record(path: "bar", stamp: .init(mtime: Date(), size: 1))
        let before = await registry.count()
        await registry.clear()
        let after = await registry.count()
        XCTAssertEqual(before, 2)
        XCTAssertEqual(after, 0)
    }

    func testStampOfURLRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTimeRegistry-\(UUID().uuidString).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let stamp = FileTimeRegistry.Stamp.of(url: url)
        XCTAssertNotNil(stamp)
        XCTAssertEqual(stamp?.size, "hello".utf8.count)
    }
}
