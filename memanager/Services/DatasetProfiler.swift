import Foundation

struct DatasetProfilerConfig {
    let pythonExecutablePath: String?
    let scriptPath: String?
    let timeoutSeconds: TimeInterval

    static let defaultsScriptKey = "memanager.mlGuideDataProfilerScriptPath"
    static let defaultsPythonKey = "memanager.mlGuidePythonPath"
    static let defaultsTimeoutKey = "memanager.mlGuideDataProfilerTimeout"

    static func load(
        defaults: UserDefaults = AppDefaults.standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DatasetProfilerConfig {
        let defaultTimeout = 8.0
        let timeoutFromDefaults = defaults.double(forKey: defaultsTimeoutKey)
        let timeoutValue = environment["MEMANAGER_DATA_PROFILER_TIMEOUT"].flatMap(Double.init)
            ?? (timeoutFromDefaults > 0 ? timeoutFromDefaults : defaultTimeout)

        return DatasetProfilerConfig(
            pythonExecutablePath: environment["MEMANAGER_DATA_PROFILER_PYTHON"] ?? defaults.string(forKey: defaultsPythonKey),
            scriptPath: environment["MEMANAGER_DATA_PROFILER_SCRIPT"] ?? defaults.string(forKey: defaultsScriptKey),
            timeoutSeconds: max(1.0, timeoutValue)
        )
    }

    var normalizedPythonPath: String? {
        normalizePath(pythonExecutablePath)
    }

    var normalizedScriptPath: String? {
        normalizePath(scriptPath)
    }

    var isConfigured: Bool {
        normalizedPythonPath != nil && normalizedScriptPath != nil
    }

    private func normalizePath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct DatasetProfilerExecution {
    let success: Bool
    let timedOut: Bool
    let output: String
    let errorOutput: String
}

protocol DatasetProfilerRunning {
    func run(
        pythonPath: String,
        scriptPath: String,
        timeoutSeconds: TimeInterval
    ) -> DatasetProfilerExecution
}

enum DatasetProfilerResult {
    case summary(String)
    case unavailable(String)
}

protocol DatasetProfiling {
    func loadDatasetSummary() async -> DatasetProfilerResult
}

final class DatasetProfiler: DatasetProfiling {
    private let config: DatasetProfilerConfig
    private let runner: DatasetProfilerRunning
    private let fileManager: FileManager

    init(
        config: DatasetProfilerConfig = .load(),
        runner: DatasetProfilerRunning = ProcessDatasetProfilerRunner(),
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.runner = runner
        self.fileManager = fileManager
    }

    func loadDatasetSummary() async -> DatasetProfilerResult {
        guard let pythonPath = config.normalizedPythonPath,
              let scriptPath = config.normalizedScriptPath else {
            return .unavailable("ML Guide dataset profiler is not configured.")
        }

        guard fileManager.fileExists(atPath: pythonPath) else {
            return .unavailable("ML Guide profiler python executable not found at \(pythonPath).")
        }

        guard fileManager.fileExists(atPath: scriptPath) else {
            return .unavailable("ML Guide profiler script not found at \(scriptPath).")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let execution = self.runner.run(
                    pythonPath: pythonPath,
                    scriptPath: scriptPath,
                    timeoutSeconds: self.config.timeoutSeconds
                )

                if execution.success {
                    let summary = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if summary.isEmpty {
                        continuation.resume(returning: .unavailable("ML Guide dataset profiler returned empty output."))
                    } else {
                        continuation.resume(returning: .summary(summary))
                    }
                    return
                }

                if execution.timedOut {
                    continuation.resume(returning: .unavailable("ML Guide dataset profiler timed out after \(Int(self.config.timeoutSeconds)) seconds."))
                    return
                }

                let errorText = execution.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: .unavailable(
                    errorText.isEmpty
                        ? "ML Guide dataset profiler failed."
                        : "ML Guide dataset profiler failed: \(errorText)"
                ))
            }
        }
    }
}

struct ProcessDatasetProfilerRunner: DatasetProfilerRunning {
    func run(
        pythonPath: String,
        scriptPath: String,
        timeoutSeconds: TimeInterval
    ) -> DatasetProfilerExecution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stateLock = NSLock()
        var timedOut = false
        do {
            try process.run()
        } catch {
            return DatasetProfilerExecution(
                success: false,
                timedOut: false,
                output: "",
                errorOutput: error.localizedDescription
            )
        }

        // Read both pipes while the child runs. Waiting for termination first
        // turns a full pipe into a false profiler timeout.
        let outputReader = ProfilerPipeReader(outputPipe.fileHandleForReading)
        let errorReader = ProfilerPipeReader(errorPipe.fileHandleForReading)

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                stateLock.lock()
                timedOut = true
                stateLock.unlock()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeoutWorkItem
        )

        process.waitUntilExit()
        timeoutWorkItem.cancel()

        stateLock.lock()
        let didTimeout = timedOut
        stateLock.unlock()

        return DatasetProfilerExecution(
            success: process.terminationStatus == 0 && !didTimeout,
            timedOut: didTimeout,
            output: outputReader.finish(),
            errorOutput: errorReader.finish()
        )
    }
}

/// The worker owns the buffer until the dispatch group joins in `finish`.
private final class ProfilerPipeReader: @unchecked Sendable {
    private let completion = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        completion.enter()
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.completion.leave()
        }
    }

    func finish() -> String {
        completion.wait()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
