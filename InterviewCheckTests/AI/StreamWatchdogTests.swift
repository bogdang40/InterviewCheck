import XCTest
@testable import InterviewCheck

final class StreamWatchdogTests: XCTestCase {
    func testStalledStreamRaisesFirstByteTimeout() async {
        let source = AsyncThrowingStream<String, Error> { _ in
            // Never yields, never finishes: a silently dead connection.
        }
        let monitored = StreamWatchdog.monitored(
            source,
            policy: StreamTimeoutPolicy(firstByte: 0.05, interChunk: 10, total: 10),
            checkInterval: 0.01
        )

        await assertTimeout(stage: .firstByte, iterating: monitored)
    }

    func testActiveStreamGoingSilentRaisesInterChunkTimeout() async {
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("first line")
            // Then silence, without finishing.
        }
        let monitored = StreamWatchdog.monitored(
            source,
            policy: StreamTimeoutPolicy(firstByte: 10, interChunk: 0.05, total: 10),
            checkInterval: 0.01
        )

        await assertTimeout(stage: .interChunk, iterating: monitored, expectedLines: ["first line"])
    }

    func testStreamExceedingTotalBudgetRaisesTotalTimeout() async {
        let source = AsyncThrowingStream<String, Error> { continuation in
            let producer = Task {
                while !Task.isCancelled {
                    continuation.yield("tick")
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
        let monitored = StreamWatchdog.monitored(
            source,
            policy: StreamTimeoutPolicy(firstByte: 10, interChunk: 10, total: 0.08),
            checkInterval: 0.01
        )

        await assertTimeout(stage: .total, iterating: monitored)
    }

    func testHealthyStreamPassesAllLinesThrough() async throws {
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("one")
            continuation.yield("two")
            continuation.finish()
        }
        let monitored = StreamWatchdog.monitored(
            source,
            policy: StreamTimeoutPolicy(firstByte: 5, interChunk: 5, total: 5),
            checkInterval: 0.01
        )

        var lines: [String] = []
        for try await line in monitored {
            lines.append(line)
        }

        XCTAssertEqual(lines, ["one", "two"])
    }

    func testSourceErrorPropagatesUnchanged() async {
        let source = AsyncThrowingStream<String, Error> { continuation in
            continuation.finish(throwing: AIProviderError.rateLimited)
        }
        let monitored = StreamWatchdog.monitored(
            source,
            policy: StreamTimeoutPolicy(firstByte: 5, interChunk: 5, total: 5),
            checkInterval: 0.01
        )

        do {
            for try await _ in monitored {}
            XCTFail("Expected source error")
        } catch {
            guard case AIProviderError.rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        }
    }

    private func assertTimeout(
        stage expectedStage: AIProviderError.TimeoutStage,
        iterating stream: AsyncThrowingStream<String, Error>,
        expectedLines: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var lines: [String] = []
        do {
            for try await streamedLine in stream {
                lines.append(streamedLine)
            }
            XCTFail("Expected timeout, stream finished normally", file: file, line: line)
        } catch {
            guard case AIProviderError.timeout(let stage) = error else {
                return XCTFail("Expected timeout error, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(stage, expectedStage, file: file, line: line)
            if !expectedLines.isEmpty {
                XCTAssertEqual(lines, expectedLines, file: file, line: line)
            }
        }
    }
}
