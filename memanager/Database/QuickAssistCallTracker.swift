import Foundation

// MARK: - Quick Assist Call Tracker

/// Tracks the lifecycle of a quick assist call
final class QuickAssistCallTracker {
    private var record: QuickAssistCallRecord
    private let database: SessionDatabase
    private let ownershipID: UUID
    private var isCompleted = false

    var lastRecordedTurnId: String? {
        record.turnId
    }
    
    init(record: QuickAssistCallRecord, database: SessionDatabase) {
        self.record = record
        self.database = database
        ownershipID = database.registerQuickAssistCallOwnership(record)
    }

    deinit {
        database.releaseQuickAssistCallOwnership(ownershipID)
    }
    
    /// Mark the call as successful with full response text
    func complete(
        responseText: String,
        rawResponseText: String? = nil,
        guardedResponseText: String? = nil,
        resolvedQuestion: String? = nil
    ) {
        guard !isCompleted else { return }
        isCompleted = true
        
        if let resolvedQuestion {
            record.question = resolvedQuestion
        }

        record = record.withCompletion(
            status: "success",
            responseLength: responseText.count,
            responseText: responseText,
            rawResponseText: rawResponseText ?? responseText,
            guardedResponseText: guardedResponseText ?? responseText
        )
        database.insertQuickAssistCall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] Quick Assist completed in \(record.durationMs ?? 0)ms, response: \(responseText.count) chars")
    }
    
    /// Mark the call as failed
    func fail(error: Error) {
        guard !isCompleted else { return }
        isCompleted = true
        
        record = record.withCompletion(
            status: "error",
            errorMessage: error.localizedDescription
        )
        database.insertQuickAssistCall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] Quick Assist failed: \(error.localizedDescription)")
    }
    
    /// Mark the call as cancelled
    func cancel() {
        guard !isCompleted else { return }
        isCompleted = true
        record.verificationStatus = .failed

        record = record.withCompletion(status: "cancelled")
        database.insertQuickAssistCall(record, ownershipID: ownershipID)
        
        NSLog("[SessionLogger] Quick Assist cancelled")
    }
}
