import Foundation

extension SessionDatabase {
    func registerAPICallOwnership(sessionId: String) -> UUID {
        let id = UUID()
        performSync { _ in apiCallOwners[id] = sessionId }
        return id
    }

    func releaseAPICallOwnership(_ id: UUID) {
        // Preserve a previously queued terminal write when the tracker is
        // released immediately afterward, and avoid synchronous queue reentry.
        performAsync { _ in self.apiCallOwners.removeValue(forKey: id) }
    }

    /// Called inside the queued terminal insert, never before enqueueing it.
    func consumeAPICallOwnership(_ id: UUID, sessionId: String) -> Bool {
        guard apiCallOwners[id] == sessionId else { return false }
        apiCallOwners.removeValue(forKey: id)
        return true
    }

    /// Queue confined. A failed deletion must leave ownership available.
    func invalidateAPICallOwnership(sessionIDs: Set<String>) {
        apiCallOwners = apiCallOwners.filter { !sessionIDs.contains($0.value) }
    }
}
