import XCTest
@testable import memanager

/// Pure rules behind the metadata form's resync: an echoed commit is
/// recognized regardless of the timestamp the store stamped on it, and a
/// foreign write only replaces the fields the form does not edit.
final class WorkspaceMetadataFormRulesTests: XCTestCase {
    func testEchoedCommitMatchesDespiteNewTimestamp() {
        let committed = JobWorkspace(name: "A", company: "Acme", role: "SWE", folderPath: "/tmp/a", notes: "n", tags: ["payments"])
        var echoed = committed
        echoed.updatedAt = committed.updatedAt.addingTimeInterval(5)
        echoed.lastOpenedAt = Date()
        XCTAssertTrue(WorkspaceMetadataForm.sameEditableContent(echoed, committed))

        var edited = echoed
        edited.tags = ["payments", "go"]
        XCTAssertFalse(WorkspaceMetadataForm.sameEditableContent(edited, committed))
    }

    func testAbsorbingStoreOwnedFieldsKeepsTypedTextAndTakesArchiveState() {
        var draft = JobWorkspace(name: "Typing", company: "Acme", role: "SWE", folderPath: "/tmp/old", notes: "half a sen")
        var incoming = draft
        incoming.isArchived = true
        incoming.folderPath = "/tmp/new"
        incoming.lastOpenedAt = Date()
        incoming.updatedAt = Date().addingTimeInterval(10)
        incoming.notes = "stale notes from the store"

        draft = WorkspaceMetadataForm.absorbingStoreOwnedFields(from: incoming, into: draft)

        XCTAssertEqual(draft.notes, "half a sen", "what is being typed survives")
        XCTAssertTrue(draft.isArchived)
        XCTAssertEqual(draft.folderPath, "/tmp/new")
        XCTAssertEqual(draft.updatedAt, incoming.updatedAt)
        XCTAssertEqual(draft.lastOpenedAt, incoming.lastOpenedAt)
    }
}
