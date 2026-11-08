import XCTest
@testable import memanager

/// The composer's character budget must survive oversized user fields
/// instead of trapping on a negative prefix length.
final class WorkspaceComposerBudgetTests: XCTestCase {
    private func document(for workspace: JobWorkspace, _ path: String, text: String) -> WorkspaceDocument {
        WorkspaceDocument(workspaceID: workspace.id, relativePath: path, kind: .markdown, category: .projects, byteSize: text.utf8.count, sha256: path, extractedText: text)
    }

    func testHeaderLargerThanTheBudgetDoesNotCrashAndStillYieldsABrief() {
        let workspace = JobWorkspace(
            name: String(repeating: "n", count: 3_000),
            company: String(repeating: "c", count: 3_000),
            role: String(repeating: "r", count: 3_000),
            folderPath: "/tmp/x",
            jobDescriptionSummary: "Own the ledger.",
            notes: String(repeating: "note ", count: 500),
            tags: (0..<400).map { "tag\($0)" }
        )
        // The bounded header alone (five fields of up to 240 characters plus
        // 400 of notes) is larger than this budget, so nothing else fits.
        let budget = WorkspaceContextBudget(totalCharacters: 800, perDocumentCharacters: 500, maxDocuments: 2, maxJournalEntries: 2, journalEntryCharacters: 200)
        let composer = WorkspaceContextComposer(budget: budget)

        let brief = composer.compose(
            workspace: workspace,
            documents: [document(for: workspace, "Projects/a.md", text: "ledger kafka idempotency")],
            journal: [WorkspaceJournalEntry(workspaceID: workspace.id, kind: .problemSolved, title: "Ledger", body: "Used idempotency keys.", createdAt: Date())],
            question: "ledger idempotency"
        )

        XCTAssertTrue(brief.text.hasPrefix("JOB WORKSPACE CONTEXT:"))
        XCTAssertEqual(brief.documentCount, 0, "nothing is left in the budget after the header")
        XCTAssertEqual(brief.journalCount, 0)
        XCTAssertFalse(brief.text.contains("Role summary:"))
        XCTAssertLessThan(brief.text.count, 1_800, "header fields are bounded so the block stays near the budget")
    }

    func testTinyBudgetSkipsTheRoleSummaryInsteadOfTrapping() {
        let workspace = JobWorkspace(name: "Short", company: "Acme", role: "SWE", folderPath: "/tmp/x", jobDescriptionSummary: "A summary that will not fit.")
        let budget = WorkspaceContextBudget(totalCharacters: 10, perDocumentCharacters: 500, maxDocuments: 1, maxJournalEntries: 1, journalEntryCharacters: 100)
        let brief = WorkspaceContextComposer(budget: budget).compose(workspace: workspace, documents: [], journal: [], question: "anything")
        XCTAssertFalse(brief.text.contains("Role summary:"))
        XCTAssertTrue(brief.text.contains("Workspace: Short"))
    }
}
