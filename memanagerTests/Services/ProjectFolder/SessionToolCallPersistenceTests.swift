import XCTest
@testable import memanager

final class SessionToolCallPersistenceTests: XCTestCase {
    func testToolCallRecordPersistsDurableDisplayFields() async throws {
        let turnID = UUID().uuidString
        let record = SessionToolCallRecord(
            sessionID: "test-session-\(UUID().uuidString)",
            threadID: "test-thread",
            turnID: turnID,
            toolName: "read_file",
            argumentsJSON: #"{"path":"Docs/Guide.md"}"#,
            displayInput: "read_file\npath: Docs/Guide.md",
            resultPreview: "Guide preview",
            resultContent: "1  # Guide",
            contentTruncated: true,
            overflowPath: "/tmp/full-tool-output.txt",
            isError: false,
            iteration: 1,
            startedAt: Date(),
            durationMs: 11
        )

        SessionDatabase.shared.logToolCall(record)

        var loaded: [SessionToolCallRecord] = []
        for _ in 0..<40 {
            loaded = SessionDatabase.shared.loadToolCalls(turnID: turnID)
            if !loaded.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let stored = loaded.first else {
            return XCTFail("expected a stored tool call row")
        }

        XCTAssertEqual(stored.displayInput, record.displayInput)
        XCTAssertEqual(stored.resultContent, record.resultContent)
        XCTAssertEqual(stored.contentTruncated, true)
        XCTAssertEqual(stored.overflowPath, record.overflowPath)
    }
}
