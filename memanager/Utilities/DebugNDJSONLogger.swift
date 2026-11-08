import Foundation

/// Minimal NDJSON logger for Cursor debug-mode runtime evidence.
/// Writes one JSON object per line to a local debug log file, rotating at a
/// size threshold (one .1 backup) and redacting credential shaped values.
final class DebugNDJSONLogger {
    static let shared = DebugNDJSONLogger()

    private let logFilePath: String
    private let rotationThresholdBytes: Int
    private let writeQueue = DispatchQueue(label: "com.memanager.DebugNDJSONLogger")

    private static let defaultRotationThresholdBytes = 10 * 1024 * 1024

    /// Key names whose values must never land in a plaintext log. Matching is
    /// deliberately narrow (exact "key" or credential substrings) so debug
    /// fields like "hotkey" or "keycode" stay useful.
    private static let redactedKeyFragments = ["apikey", "api_key", "token", "secret", "authorization", "password"]

    private convenience init() {
        self.init(
            logFilePath: DebugNDJSONLogger.resolveLogFilePath(),
            rotationThresholdBytes: DebugNDJSONLogger.defaultRotationThresholdBytes
        )
    }

    /// Internal so tests can target a temp file with a tiny threshold.
    init(logFilePath: String, rotationThresholdBytes: Int) {
        self.logFilePath = logFilePath
        self.rotationThresholdBytes = rotationThresholdBytes
    }

    func log(
        sessionId: String = "debug-session",
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": sanitize(data),
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]

        writeQueue.async { [logFilePath, rotationThresholdBytes] in
            guard
                let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
                let line = String(data: json, encoding: .utf8)
            else { return }

            let url = URL(fileURLWithPath: logFilePath)
            let directoryURL = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }

            Self.rotateIfNeeded(path: logFilePath, thresholdBytes: rotationThresholdBytes)

            if !FileManager.default.fileExists(atPath: logFilePath) {
                FileManager.default.createFile(atPath: logFilePath, contents: nil)
            }

            do {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = (line + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                try handle.close()
            } catch {
                // Intentionally ignore logging failures in debug instrumentation.
            }
        }
    }

    /// Blocks until previously queued writes hit the file. Test hook.
    func drain() {
        writeQueue.sync {}
    }

    private static func rotateIfNeeded(path: String, thresholdBytes: Int) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int,
            size >= thresholdBytes
        else { return }

        let backupPath = path + ".1"
        try? FileManager.default.removeItem(atPath: backupPath)
        try? FileManager.default.moveItem(atPath: path, toPath: backupPath)
    }

    func sanitize(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as Int: return v
        case let v as Int64: return v
        case let v as UInt: return v
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as Bool: return v
        case let v as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(v.count)
            for (k, val) in v {
                if Self.isSensitiveKey(k) {
                    out[k] = "<redacted>"
                } else {
                    out[k] = sanitize(val)
                }
            }
            return out
        case let v as [Any]:
            return v.map { sanitize($0) }
        case _ as NSNull:
            return NSNull()
        default:
            // Avoid attempting to encode unsupported types; stringify.
            return String(describing: value)
        }
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        if lowered == "key" {
            return true
        }
        return redactedKeyFragments.contains { lowered.contains($0) }
    }

    private static func resolveLogFilePath() -> String {
        if TestRuntime.isRunningUnitTests {
            return TestRuntime.temporaryDirectory.appendingPathComponent("debug.log").path
        }
        let env = ProcessInfo.processInfo.environment
        if let path = env["MEMANAGER_DEBUG_LOG_PATH"], !path.isEmpty {
            return path
        }
        if let dir = env["MEMANAGER_DEBUG_LOG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("debug.log").path
        }

        let cwd = FileManager.default.currentDirectoryPath
        let cursorDir = URL(fileURLWithPath: cwd).appendingPathComponent(".cursor")
        if FileManager.default.fileExists(atPath: cursorDir.path) {
            return cursorDir.appendingPathComponent("debug.log").path
        }

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/memanager")
        return logsDir.appendingPathComponent("debug.log").path
    }
}
