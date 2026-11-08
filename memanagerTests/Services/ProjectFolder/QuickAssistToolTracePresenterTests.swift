import XCTest
@testable import memanager

final class QuickAssistToolTracePresenterTests: XCTestCase {
    private let presenter = QuickAssistToolTracePresenter()

    func testSearchFilesTraceGroupsMatchesByFileAndLine() {
        let record = SessionToolCallRecord(
            sessionID: "session",
            threadID: "thread",
            turnID: "turn",
            toolName: "search_files",
            argumentsJSON: #"{"pattern":"SessionController","path":"memanager"}"#,
            displayInput: "search_files\npattern: SessionController\npath: memanager",
            resultPreview: nil,
            resultContent: """
            memanager/Services/SessionController.swift:42: final class SessionController {
              memanager/Services/SessionController.swift:41: 
            memanager/Views/MentorView.swift:12: @ObservedObject private var controller = SessionController.shared
            """,
            contentTruncated: false,
            overflowPath: nil,
            isError: false,
            iteration: 1,
            startedAt: Date(),
            durationMs: 14
        )

        let trace = presenter.present(records: [record], turnID: nil)
        guard let step = trace.steps.first else {
            return XCTFail("expected a trace step")
        }

        XCTAssertEqual(step.referencedFiles.count, 2)
        switch step.evidenceKind {
        case .search(let pattern, let scopePath, let groups):
            XCTAssertEqual(pattern, "SessionController")
            XCTAssertEqual(scopePath, "memanager")
            XCTAssertEqual(groups.first?.path, "memanager/Services/SessionController.swift")
            XCTAssertEqual(groups.first?.lines.first?.lineNumber, 42)
        default:
            XCTFail("expected search evidence")
        }
    }

    func testReadFileTraceBuildsMonospaceExcerptWithLineWindow() {
        let record = SessionToolCallRecord(
            sessionID: "session",
            threadID: "thread",
            turnID: "turn",
            toolName: "read_file",
            argumentsJSON: #"{"path":"memanager/Services/SessionController.swift"}"#,
            displayInput: "read_file\npath: memanager/Services/SessionController.swift",
            resultPreview: nil,
            resultContent: """
                40  final class SessionController {
                41      static let shared = SessionController()
                42  
            """,
            contentTruncated: false,
            overflowPath: nil,
            isError: false,
            iteration: 2,
            startedAt: Date(),
            durationMs: 9
        )

        let trace = presenter.present(records: [record], turnID: nil)
        guard let step = trace.steps.first else {
            return XCTFail("expected a trace step")
        }

        switch step.evidenceKind {
        case .read(let excerpt):
            XCTAssertEqual(excerpt.path, "memanager/Services/SessionController.swift")
            XCTAssertEqual(excerpt.startLine, 40)
            XCTAssertEqual(excerpt.endLine, 42)
            XCTAssertTrue(excerpt.snippet.contains("41:"))
        default:
            XCTFail("expected read evidence")
        }
    }

    func testTracePreservesTruncationAndOverflowMetadata() {
        let overflowPath = "/tmp/tool-output.txt"
        let record = SessionToolCallRecord(
            sessionID: "session",
            threadID: "thread",
            turnID: "turn",
            toolName: "glob",
            argumentsJSON: #"{"pattern":"**/*.swift"}"#,
            displayInput: "glob\npattern: **/*.swift",
            resultPreview: nil,
            resultContent: "memanager/Services/SessionController.swift\n(truncated; full output saved to /tmp/tool-output.txt)",
            contentTruncated: true,
            overflowPath: overflowPath,
            isError: false,
            iteration: 1,
            startedAt: Date(),
            durationMs: 4
        )

        let trace = presenter.present(records: [record], turnID: nil)
        XCTAssertEqual(trace.steps.first?.overflowPath, overflowPath)
        XCTAssertEqual(trace.steps.first?.contentTruncated, true)
    }
}
