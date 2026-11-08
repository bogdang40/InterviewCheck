import Foundation

/// Drains both pipes concurrently, retains a bounded prefix, and owns the
/// subprocess until its pipes close. A limit failure never looks like a complete search.
enum RipgrepProcessRunner {
    struct Output {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func run(
        binary: URL,
        args: [String],
        cwd: URL,
        maximumOutputBytes: Int = 16 * 1024 * 1024
    ) async throws -> Output {
        try Task.checkCancellation()
        let execution = RipgrepProcessExecution(
            binary: binary,
            args: args,
            cwd: cwd,
            maximumOutputBytes: max(0, maximumOutputBytes)
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// The lock orders cancellation against launch and guards the single completion.
/// Blocking pipe reads stay on dispatch queues, outside Swift's cooperative executor.
private final class RipgrepProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let reads = DispatchGroup()
    private let maximumOutputBytes: Int
    private var continuation: CheckedContinuation<RipgrepProcessRunner.Output, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var failure: Error?
    private var cancelled = false
    private var didLaunch = false
    private var stopRequested = false

    init(binary: URL, args: [String], cwd: URL, maximumOutputBytes: Int) {
        self.maximumOutputBytes = maximumOutputBytes
        process.executableURL = binary
        process.arguments = args
        process.currentDirectoryURL = cwd
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(_ continuation: CheckedContinuation<RipgrepProcessRunner.Output, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        read(stdoutPipe.fileHandleForReading, isStandardError: false)
        read(stderrPipe.fileHandleForReading, isStandardError: true)
        process.terminationHandler = { [self] process in
            reads.notify(queue: .global(qos: .utility)) { [self] in
                finish(exitCode: process.terminationStatus)
            }
        }
        do {
            try process.run()
            didLaunch = true
            lock.unlock()
        } catch {
            failure = RipgrepError.spawnFailed(error.localizedDescription)
            lock.unlock()
            // No child can close the write ends after a failed launch.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            reads.notify(queue: .global(qos: .utility)) { [self] in
                finish(exitCode: -1)
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            stopLocked()
        }
    }

    private func read(_ handle: FileHandle, isStandardError: Bool) {
        reads.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                reads.leave()
            }
            do {
                while let data = try handle.read(upToCount: 16 * 1024), !data.isEmpty {
                    lock.withLock {
                        let count = isStandardError ? stderr.count : stdout.count
                        let retained = data.prefix(maximumOutputBytes - count)
                        if isStandardError { stderr.append(contentsOf: retained) }
                        else { stdout.append(contentsOf: retained) }
                        if retained.count < data.count, failure == nil {
                            failure = RipgrepError.outputLimitExceeded(
                                stream: isStandardError ? "stderr" : "stdout",
                                limit: maximumOutputBytes
                            )
                            stopLocked()
                        }
                    }
                }
            } catch {
                lock.withLock {
                    if failure == nil {
                        failure = RipgrepError.outputReadFailed(error.localizedDescription)
                    }
                    stopLocked()
                }
            }
        }
    }

    /// Called under the lock so a cancellation before launch cannot miss the child.
    private func stopLocked() {
        guard didLaunch, process.isRunning, !stopRequested else { return }
        stopRequested = true
        process.terminate()
        // A stuck child must not hold the caller forever after cancellation or overflow.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.withLock {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let result: Result<RipgrepProcessRunner.Output, Error>
        if cancelled { result = .failure(CancellationError()) }
        else if let failure { result = .failure(failure) }
        else {
            result = .success(.init(
                stdout: String(decoding: stdout, as: UTF8.self),
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: exitCode
            ))
        }
        process.terminationHandler = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
