import XCTest
@testable import memanager

final class RipgrepProcessCancellationTests: XCTestCase {
    func testCancelledTaskDoesNotLaunchChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RipgrepProcessRunner.run(
                binary: URL(fileURLWithPath: "/usr/bin/touch"),
                args: [marker.path],
                cwd: FileManager.default.temporaryDirectory
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testCancellationStopsChildEvenWhenTerminationSignalIsIgnored() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await RipgrepProcessRunner.run(
                binary: URL(fileURLWithPath: "/bin/sh"),
                args: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 20", "test", marker.path],
                cwd: FileManager.default.temporaryDirectory
            )
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidText = try String(contentsOf: marker, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            XCTAssertEqual(kill(pid, 0), -1, "The cancelled child must be reaped before returning")
        }
    }

    func testOutputLimitRejectsIncompleteSearchForEitherPipe() async throws {
        for redirect in ["", " >&2"] {
            do {
                _ = try await RipgrepProcessRunner.run(
                    binary: URL(fileURLWithPath: "/bin/sh"),
                    args: ["-c", "printf '%4096s' x\(redirect)"],
                    cwd: FileManager.default.temporaryDirectory,
                    maximumOutputBytes: 1024
                )
                XCTFail("Expected explicit output limit error")
            } catch RipgrepError.outputLimitExceeded(let stream, let limit) {
                XCTAssertEqual(stream, redirect.isEmpty ? "stdout" : "stderr")
                XCTAssertEqual(limit, 1024)
            }
        }
    }

    func testExactOutputLimitPreservesCompleteOutput() async throws {
        let output = try await RipgrepProcessRunner.run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            args: ["-c", "printf '1234'; printf '5678' >&2"],
            cwd: FileManager.default.temporaryDirectory,
            maximumOutputBytes: 4
        )
        XCTAssertEqual(output.stdout, "1234")
        XCTAssertEqual(output.stderr, "5678")
        XCTAssertEqual(output.exitCode, 0)
    }
}
