import Foundation

struct QuickAssistCallOwnership {
    let sessionId: String
    let threadId: String
    let turnId: String
}

extension SessionDatabase {
    func registerQuickAssistCallOwnership(_ call: QuickAssistCallRecord) -> UUID {
        let id = UUID()
        performSync { _ in
            quickAssistCallOwners[id] = QuickAssistCallOwnership(
                sessionId: call.sessionId, threadId: call.threadId, turnId: call.turnId
            )
        }
        return id
    }

    func releaseQuickAssistCallOwnership(_ id: UUID) {
        // A tracker can release its last reference on any queue. Enqueue the
        // cleanup rather than synchronously reentering the database queue.
        performAsync { _ in self.quickAssistCallOwners.removeValue(forKey: id) }
    }

    /// Called only inside the terminal write's database queue operation.
    func consumeQuickAssistCallOwnership(_ id: UUID, call: QuickAssistCallRecord) -> Bool {
        guard let owner = quickAssistCallOwners[id],
              owner.sessionId == call.sessionId, owner.threadId == call.threadId,
              owner.turnId == call.turnId else { return false }
        quickAssistCallOwners.removeValue(forKey: id)
        return true
    }

    /// Called on the database queue only after the deletion transaction commits.
    /// Keeping only active requests avoids persistent tombstones and reused IDs.
    func invalidateQuickAssistCallOwnership(sessionIDs: Set<String> = [], threadIDs: Set<String> = []) {
        quickAssistCallOwners = quickAssistCallOwners.filter { _, owner in
            !sessionIDs.contains(owner.sessionId) && !threadIDs.contains(owner.threadId)
        }
    }
}
