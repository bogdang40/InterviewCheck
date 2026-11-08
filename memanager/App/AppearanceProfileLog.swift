import Foundation
import OSLog

/// Diagnostic output is opt in and serialized off the render thread. Existing
/// files are never overwritten, and no session or credential data is recorded.
final class AppearanceProfileLog: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.memanager.app", category: "AppearanceAudit")
    private let queue = DispatchQueue(label: "com.memanager.appearance-audit", qos: .utility)
    private let handle: FileHandle?

    init(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--appearance-audit-output") else {
            handle = nil
            return
        }
        do {
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            try Data().write(to: url, options: .withoutOverwriting)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            handle = nil
            Self.logger.error("Appearance audit output unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func append(_ fields: [String: Any]) {
        guard let handle else { return }
        queue.async {
            do {
                var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                Self.logger.error("Appearance audit write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func finish() {
        guard let handle else { return }
        queue.sync {
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                Self.logger.error("Appearance audit close failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
