import XCTest
@testable import memanager

final class FSIndexActorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(RipgrepBinaryLocator.shared.locate() == nil, "ripgrep not installed")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeText("hello", to: "Sources/A.swift")
        try writeText("world", to: "Sources/B.swift")
        try writeText("ignored", to: "Docs/ReadMe.md")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testWarmPopulatesIndex() async throws {
        let index = FSIndexActor()
        try await index.warm(root: root)
        let count = await index.count()
        let warm = await index.isWarm()
        XCTAssertEqual(count, 3)
        XCTAssertTrue(warm)
    }

    func testFilesFiltersByGlob() async throws {
        let index = FSIndexActor()
        try await index.warm(root: root)
        let swift = await index.files(globPattern: "**/*.swift")
        XCTAssertEqual(swift.count, 2)
        for record in swift {
            XCTAssertEqual(record.languageKind, .swift)
        }
    }

    func testFilesFiltersByExtension() async throws {
        let index = FSIndexActor()
        try await index.warm(root: root)
        let md = await index.files(extensions: ["md"])
        XCTAssertEqual(md.map { $0.relativePath }, ["Docs/ReadMe.md"])
    }

    func testInvalidateUpdatesExistingRecord() async throws {
        let index = FSIndexActor()
        try await index.warm(root: root)
        let initial = await index.record(relativePath: "Sources/A.swift")
        XCTAssertNotNil(initial)
        try writeText("new content here", to: "Sources/A.swift")
        await index.invalidate(paths: ["Sources/A.swift"], root: root)
        let updated = await index.record(relativePath: "Sources/A.swift")
        XCTAssertNotNil(updated)
        XCTAssertGreaterThan(updated!.size, initial!.size)
    }

    func testInvalidateRemovesDeletedFile() async throws {
        let index = FSIndexActor()
        try await index.warm(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/A.swift"))
        await index.invalidate(paths: ["Sources/A.swift"], root: root)
        let record = await index.record(relativePath: "Sources/A.swift")
        XCTAssertNil(record)
    }

    func testGlobMatcherHandlesDoubleStar() {
        let matcher = FSIndexGlobMatcher(pattern: "**/*.swift")
        XCTAssertNotNil(matcher)
        XCTAssertTrue(matcher!.matches("Sources/A.swift"))
        XCTAssertTrue(matcher!.matches("a.swift"))
        XCTAssertFalse(matcher!.matches("a.py"))
    }

    private func writeText(_ text: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class FSIndexActorWarmTests: XCTestCase {
    func testConcurrentWarmRequestsShareOneScan() async throws {
        let fixture = try WarmFixture()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await fixture.index.warm(root: fixture.root) }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(try fixture.callCount(), 2, "One scan runs visible and ignored file listings")
        let record = await fixture.index.record(relativePath: "A.swift")
        XCTAssertNotNil(record)
    }

    func testFailedWarmCanBeRetried() async throws {
        let fixture = try WarmFixture()
        let failure = fixture.root.appendingPathComponent("fail")
        try Data().write(to: failure)
        do {
            try await fixture.index.warm(root: fixture.root)
            XCTFail("Expected listing failure")
        } catch RipgrepError.nonZeroExit {
            // A later request must retry instead of retaining the failed task.
        }
        try FileManager.default.removeItem(at: failure)
        try await fixture.index.warm(root: fixture.root)
        let warm = await fixture.index.isWarm()
        XCTAssertTrue(warm)
        XCTAssertEqual(try fixture.callCount(), 4)
    }

    func testResetDiscardsInFlightScanAndAllowsFreshWarm() async throws {
        let fixture = try WarmFixture()
        let hold = fixture.root.appendingPathComponent("hold")
        try Data().write(to: hold)
        defer { try? FileManager.default.removeItem(at: hold) }
        let stale = Task { try await fixture.index.warm(root: fixture.root) }
        try await fixture.waitForCalls(2)
        await fixture.index.reset()
        try "B.swift".write(to: fixture.root.appendingPathComponent("response"), atomically: true, encoding: .utf8)
        let fresh = Task { try await fixture.index.warm(root: fixture.root) }
        try await fixture.waitForCalls(4)
        try FileManager.default.removeItem(at: hold)
        try await fresh.value
        do {
            try await stale.value
            XCTFail("Reset should cancel the stale scan")
        } catch is CancellationError {
            // The old snapshot must not overwrite the fresh generation.
        }
        let paths = await fixture.index.files().map(\.relativePath)
        XCTAssertEqual(paths, ["B.swift"])
    }

    private final class WarmFixture: @unchecked Sendable {
        let root: URL
        let index: FSIndexActor

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("FSWarmTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let binary = root.appendingPathComponent("rg-fixture")
            try """
            #!/bin/sh
            response=$(/bin/cat response)
            printf 'call\\n' >> calls
            while [ -f hold ]; do /bin/sleep 0.01; done
            /bin/sleep 0.1
            if [ -f fail ]; then exit 2; fi
            printf '%s\\n' "$response"
            """.write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try "A.swift".write(to: root.appendingPathComponent("response"), atomically: true, encoding: .utf8)
            let service = RipgrepService(locator: RipgrepBinaryLocator(candidatePaths: [binary.path]))
            index = FSIndexActor(warmer: FSIndexWarmer(ripgrep: service))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func callCount() throws -> Int {
            try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").count
        }

        func waitForCalls(_ expected: Int) async throws {
            for _ in 0..<200 {
                if (try? callCount()) ?? 0 >= expected { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw NSError(domain: "FSIndexActorWarmTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Scan did not start"])
        }
    }
}
