import XCTest
@testable import memanager

final class RipgrepServiceTests: XCTestCase {
    private var fixture: ProjectToolTestFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(RipgrepBinaryLocator().locate() == nil, "ripgrep not installed")
        fixture = try ProjectToolTestFixture()
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func testSearchReturnsMatchesForKnownPattern() async throws {
        let service = RipgrepService.shared
        let opts = RipgrepService.SearchOptions(
            pattern: "Conversation",
            scope: fixture.rootURL
        )
        let matches = try await service.search(opts)
        XCTAssertFalse(matches.isEmpty, "expected at least one match for 'Conversation'")
        let paths = Set(matches.map { $0.relativePath })
        XCTAssertTrue(paths.contains("Sources/Conversation.swift"))
    }

    func testSearchRespectsCaseSensitivity() async throws {
        let service = RipgrepService.shared

        var sensitive = RipgrepService.SearchOptions(pattern: "conversation", scope: fixture.rootURL)
        sensitive.caseSensitive = true
        let sensitiveMatches = try await service.search(sensitive)
        for match in sensitiveMatches {
            XCTAssertTrue(match.lineText.contains("conversation"), "case sensitive match must contain lowercase pattern: \(match.lineText)")
        }

        var insensitive = RipgrepService.SearchOptions(pattern: "conversation", scope: fixture.rootURL)
        insensitive.caseSensitive = false
        let insensitiveMatches = try await service.search(insensitive)
        XCTAssertGreaterThan(insensitiveMatches.count, sensitiveMatches.count, "smart case should match more than case sensitive")
    }

    func testSearchProducesContextLinesWhenRequested() async throws {
        let service = RipgrepService.shared
        var opts = RipgrepService.SearchOptions(pattern: "Conversation", scope: fixture.rootURL)
        opts.contextBefore = 1
        opts.contextAfter = 1
        let matches = try await service.search(opts)
        let hit = matches.first { $0.relativePath == "Sources/Conversation+Display.swift" }
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.contextBefore.isEmpty == false || hit?.contextAfter.isEmpty == false)
    }

    func testFilesReturnsRelativePaths() async throws {
        let service = RipgrepService.shared
        let opts = RipgrepService.FileListOptions(scope: fixture.rootURL, pattern: "**/*.swift")
        let hits = try await service.files(opts)
        let paths = Set(hits.map { $0.relativePath })
        XCTAssertTrue(paths.contains("Sources/Conversation.swift"))
        XCTAssertTrue(paths.contains("Sources/Mode.swift"))
    }

    func testBinaryLocatorReturnsNonNilOnDevMachine() {
        XCTAssertNotNil(RipgrepBinaryLocator().locate())
    }

    func testMissingBinaryYieldsBinaryNotFound() async throws {
        let locator = RipgrepBinaryLocator(candidatePaths: ["/var/empty/nonexistent-rg-\(UUID().uuidString)"])
        let service = RipgrepService(locator: locator)
        let opts = RipgrepService.SearchOptions(pattern: "x", scope: fixture.rootURL)
        do {
            _ = try await service.search(opts)
            XCTFail("expected binaryNotFound")
        } catch RipgrepError.binaryNotFound {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class RipgrepProcessRunnerTests: XCTestCase {
    func testDrainsBothPipesBeyondPipeCapacityAndPreservesExitCode() async throws {
        // The watchdog makes a pipe deadlock fail this test instead of hanging
        // the test process. Both streams exceed the operating system pipe cap.
        let script = """
        (/bin/sleep 5; kill -TERM $$) >/dev/null 2>&1 &
        watchdog=$!
        trap 'kill "$watchdog" 2>/dev/null' EXIT
        i=0
        while [ "$i" -lt 256 ]; do
            printf '%4096s' x
            printf '%4096s' y >&2
            i=$((i+1))
        done
        exit 7
        """
        let result = try await RipgrepProcessRunner.run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", script],
            cwd: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, String(repeating: String(repeating: " ", count: 4095) + "x", count: 256))
        XCTAssertEqual(result.stderr, String(repeating: String(repeating: " ", count: 4095) + "y", count: 256))
    }

    func testReportsSpawnFailure() async {
        do {
            _ = try await RipgrepProcessRunner.run(
                binary: URL(fileURLWithPath: "/var/empty/nonexistent-rg-\(UUID().uuidString)"),
                args: [],
                cwd: FileManager.default.temporaryDirectory
            )
            XCTFail("Expected spawn failure")
        } catch RipgrepError.spawnFailed {
            // Preserve the runner's error contract for RipgrepService callers.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
