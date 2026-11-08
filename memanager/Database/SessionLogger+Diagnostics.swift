import Foundation

extension SessionLogger {
    // MARK: - Debug Event Logging
    
    /// Log a debug event for crash investigation
    func logDebugEvent(
        category: String,
        name: String,
        type: String = "lifecycle",
        details: String? = nil,
        includeStackTrace: Bool = false,
        includeMemory: Bool = true
    ) {
        let policy = debugSamplingPolicy.decision(
            category: category,
            name: name,
            type: type,
            requestedIncludeMemory: includeMemory
        )

        guard policy.shouldPersist || policy.shouldConsoleLog else {
            return
        }

        // Caps keep single rows bounded: details at 4 KB, stack traces at 20
        // frames (a full callStackSymbols dump per error was the largest
        // single contributor to debug_events growth).
        let event = DebugEventRecord(
            sessionId: state.sessionId,
            eventType: type,
            eventCategory: category,
            eventName: name,
            details: details.map { String($0.prefix(4096)) },
            stackTrace: includeStackTrace ? Thread.callStackSymbols.prefix(20).joined(separator: "\n") : nil,
            threadInfo: DebugEventRecord.currentThreadInfo(),
            memoryUsageMB: policy.includeMemory ? DebugEventRecord.currentMemoryMB() : nil
        )
        if policy.shouldPersist {
            database.insertDebugEvent(event)
        }

        if policy.shouldConsoleLog {
            NSLog("[Debug:\(category)] \(name)\(details.map { " - \($0)" } ?? "")")
        }
    }
    
    /// Log system design flow event
    func logSystemDesignEvent(name: String, details: String? = nil) {
        logDebugEvent(
            category: "system_design",
            name: name,
            details: details
        )
    }
    
    /// Log Mermaid diagram event
    func logMermaidEvent(name: String, details: String? = nil, isError: Bool = false) {
        logDebugEvent(
            category: "mermaid",
            name: name,
            type: isError ? "error" : "lifecycle",
            details: details,
            includeStackTrace: isError
        )
    }
    
    /// Log WebView lifecycle event
    func logWebViewEvent(name: String, details: String? = nil) {
        logDebugEvent(
            category: "webview",
            name: name,
            details: details
        )
    }
    
    /// Log view lifecycle event
    func logViewEvent(name: String, viewName: String, details: String? = nil) {
        logDebugEvent(
            category: "view",
            name: name,
            details: "view=\(viewName)\(details.map { ", \($0)" } ?? "")"
        )
    }
    
    /// Log navigation event (section changes, hotkeys)
    func logNavigationEvent(name: String, from: String? = nil, to: String? = nil, details: String? = nil) {
        var detailParts: [String] = []
        if let from = from { detailParts.append("from=\(from)") }
        if let to = to { detailParts.append("to=\(to)") }
        if let details = details { detailParts.append(details) }
        
        logDebugEvent(
            category: "navigation",
            name: name,
            type: "navigation",
            details: detailParts.isEmpty ? nil : detailParts.joined(separator: ", ")
        )
    }
    
    /// Log an error event with full context
    func logError(category: String, name: String, error: Error, details: String? = nil) {
        let errorDetails = "error=\(error.localizedDescription)\(details.map { ", \($0)" } ?? "")"
        logDebugEvent(
            category: category,
            name: name,
            type: "error",
            details: errorDetails,
            includeStackTrace: true
        )
    }
    
    /// Get recent debug events (for debugging UI)
    func getRecentDebugEvents(category: String? = nil, limit: Int = 100) -> [DebugEventRecord] {
        return database.getRecentDebugEvents(category: category, limit: limit)
    }
    
}
