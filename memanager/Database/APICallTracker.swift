import Foundation

// MARK: - API Call Tracker

/// Tracks the lifecycle of an API call for logging
final class APICallTracker {
    private var record: APICallRecord
    private let database: SessionDatabase
    private let ownershipID: UUID
    private var isCompleted = false
    
    init(record: APICallRecord, database: SessionDatabase) {
        self.record = record
        self.database = database
        ownershipID = database.registerAPICallOwnership(sessionId: record.sessionId)
    }

    deinit {
        database.releaseAPICallOwnership(ownershipID)
    }
    
    /// Mark the call as successful with full response payload
    func complete(responsePayload: String? = nil) {
        guard !isCompleted else { return }
        isCompleted = true
        
        record = record.withCompletion(
            status: "success",
            responseSizeBytes: responsePayload?.utf8.count,
            responsePayload: responsePayload
        )
        database.insertAPICall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] API call completed: \(record.callType) in \(record.durationMs ?? 0)ms, response: \(responsePayload?.count ?? 0) chars")
    }
    
    /// Mark the call as failed
    func fail(error: Error) {
        guard !isCompleted else { return }
        isCompleted = true

        record = record.withCompletion(
            status: "error",
            errorMessage: error.localizedDescription
        )
        database.insertAPICall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] API call failed: \(record.callType) - \(error.localizedDescription)")
    }
    
    /// Mark the call as cancelled
    func cancel() {
        guard !isCompleted else { return }
        isCompleted = true
        
        record = record.withCompletion(status: "cancelled")
        database.insertAPICall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] API call cancelled: \(record.callType)")
    }
}
