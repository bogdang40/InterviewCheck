import Foundation

struct DebugEventRecord {
    let sessionId: String?
    let eventType: String    // "lifecycle", "error", "navigation", "render", "api"
    let eventCategory: String // "system_design", "mermaid", "webview", "hotkey", "view"
    let eventName: String     // specific event name
    var details: String?      // JSON or text with additional context
    var stackTrace: String?   // for errors
    var threadInfo: String?   // thread name/id
    var memoryUsageMB: Double?
    let timestamp: Date
    
    init(
        sessionId: String? = nil,
        eventType: String,
        eventCategory: String,
        eventName: String,
        details: String? = nil,
        stackTrace: String? = nil,
        threadInfo: String? = nil,
        memoryUsageMB: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionId = sessionId
        self.eventType = eventType
        self.eventCategory = eventCategory
        self.eventName = eventName
        self.details = details
        self.stackTrace = stackTrace
        self.threadInfo = threadInfo
        self.memoryUsageMB = memoryUsageMB
        self.timestamp = timestamp
    }
    
    /// Get current memory usage in MB
    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1024 / 1024 : 0
    }
    
    /// Get current thread info string
    static func currentThreadInfo() -> String {
        let thread = Thread.current
        let isMain = thread.isMainThread
        let name = thread.name ?? "unnamed"
        return isMain ? "main" : "bg:\(name)"
    }
}

// MARK: - Provider Stats Record

struct ProviderStatsRecord {
    let date: String
    let provider: String
    let model: String
    let callType: String
    let callCount: Int
    let successCount: Int
    let errorCount: Int
    let totalDurationMs: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    
    var successRate: Double {
        guard callCount > 0 else { return 0 }
        return Double(successCount) / Double(callCount)
    }
    
    var avgDurationMs: Double {
        guard successCount > 0 else { return 0 }
        return Double(totalDurationMs) / Double(successCount)
    }
    
    var avgTokensPerCall: Double {
        guard successCount > 0 else { return 0 }
        return Double(totalInputTokens + totalOutputTokens) / Double(successCount)
    }
}

// MARK: - Hub Memory Records
