import XCTest
@testable import memanager

final class DatasetProfilerTests: XCTestCase {
    func testReturnsUnavailableWhenNotConfigured() async {
        let config = DatasetProfilerConfig(
            pythonExecutablePath: nil,
            scriptPath: nil,
            timeoutSeconds: 2
        )
        let profiler = DatasetProfiler(
            config: config,
            runner: StubDatasetRunner(),
            fileManager: FileManager.default
        )

        let result = await profiler.loadDatasetSummary()
        switch result {
        case .unavailable(let message):
            XCTAssertTrue(message.contains("not configured"))
        case .summary:
            XCTFail("Expected unavailable result")
        }
    }

    func testReturnsSummaryOnSuccessfulExecution() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let pythonPath = tempDir.appendingPathComponent("python").path
        let scriptPath = tempDir.appendingPathComponent("script.py").path
        FileManager.default.createFile(atPath: pythonPath, contents: Data(), attributes: nil)
        FileManager.default.createFile(atPath: scriptPath, contents: Data(), attributes: nil)

        let config = DatasetProfilerConfig(
            pythonExecutablePath: pythonPath,
            scriptPath: scriptPath,
            timeoutSeconds: 2
        )
        let runner = StubDatasetRunner(result: DatasetProfilerExecution(
            success: true,
            timedOut: false,
            output: "  summary text  ",
            errorOutput: ""
        ))
        let profiler = DatasetProfiler(config: config, runner: runner, fileManager: FileManager.default)

        let result = await profiler.loadDatasetSummary()
        switch result {
        case .summary(let summary):
            XCTAssertEqual(summary, "summary text")
        case .unavailable(let message):
            XCTFail("Expected summary, got unavailable: \(message)")
        }
    }
}

final class ProcessDatasetProfilerRunnerTests: XCTestCase {
    func testLargeOutputCompletesWithoutFalseTimeout() throws {
        let result = try runScript("""
        i=0
        while [ "$i" -lt 256 ]; do
            printf '%4096s' x
            printf '%4096s' y >&2
            i=$((i+1))
        done
        """, timeout: 5)

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output, String(repeating: String(repeating: " ", count: 4095) + "x", count: 256))
        XCTAssertEqual(result.errorOutput, String(repeating: String(repeating: " ", count: 4095) + "y", count: 256))
    }

    func testTimeoutRetainsOutputAlreadyReceived() throws {
        let result = try runScript("printf 'before timeout'; while :; do :; done", timeout: 0.15)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.output, "before timeout")
    }

    private func runScript(_ source: String, timeout: TimeInterval) throws -> DatasetProfilerExecution {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("profiler-test-\(UUID().uuidString).sh")
        try source.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        return ProcessDatasetProfilerRunner().run(
            pythonPath: "/bin/sh",
            scriptPath: script.path,
            timeoutSeconds: timeout
        )
    }
}

private struct StubDatasetRunner: DatasetProfilerRunning {
    var result = DatasetProfilerExecution(
        success: false,
        timedOut: false,
        output: "",
        errorOutput: "stub failure"
    )

    func run(
        pythonPath: String,
        scriptPath: String,
        timeoutSeconds: TimeInterval
    ) -> DatasetProfilerExecution {
        result
    }
}
