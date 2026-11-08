import XCTest
@testable import memanager

final class WorkspaceContextComposerTests: XCTestCase {
    private let workspace = JobWorkspace(
        name: "Stripe Staff",
        company: "Stripe",
        role: "Staff Engineer",
        status: .interviewing,
        folderPath: "/tmp/x",
        jobDescriptionSummary: "Own the ledger. Kafka, Go, idempotency.",
        notes: "Panel next Tuesday",
        tags: ["payments"]
    )

    private func document(_ path: String, category: WorkspaceDocumentCategory, text: String) -> WorkspaceDocument {
        WorkspaceDocument(workspaceID: workspace.id, relativePath: path, kind: .markdown, category: category, byteSize: text.utf8.count, sha256: path, extractedText: text)
    }

    func testBriefLeadsWithHeaderSummaryAndRelevantMaterial() {
        let documents = [
            document("Projects/kafka.md", category: .projects, text: "Migrated the ledger to Kafka with exactly once semantics and idempotent consumers."),
            document("Notes/comp.md", category: .notes, text: "Compensation bands and equity refresh details."),
        ]
        let journal = [
            WorkspaceJournalEntry(workspaceID: workspace.id, kind: .problemSolved, title: "Idempotency keys", body: "Store request hash keyed by client id.", createdAt: Date()),
            WorkspaceJournalEntry(workspaceID: workspace.id, kind: .note, title: "Parking", body: "Garage on 5th", createdAt: Date(timeIntervalSinceNow: -86_400 * 40)),
        ]
        let brief = WorkspaceContextComposer(budget: .default).compose(workspace: workspace, documents: documents, journal: journal, question: "How did you handle idempotency with Kafka?")

        XCTAssertTrue(brief.text.hasPrefix("JOB WORKSPACE CONTEXT:"))
        XCTAssertTrue(brief.text.contains("Company: Stripe"))
        XCTAssertTrue(brief.text.contains("Stage: Interviewing"))
        XCTAssertTrue(brief.text.contains("Role summary:"))
        XCTAssertTrue(brief.text.contains("Idempotency keys"))
        let kafkaRange = brief.text.range(of: "Projects/kafka.md")
        let compRange = brief.text.range(of: "Notes/comp.md")
        XCTAssertNotNil(kafkaRange)
        if let kafkaRange, let compRange {
            XCTAssertLessThan(kafkaRange.lowerBound, compRange.lowerBound, "the relevant project must outrank comp notes")
        }
        XCTAssertEqual(brief.journalCount, 2)
    }

    func testBriefRespectsTotalBudget() {
        let big = String(repeating: "distributed systems tradeoffs consistency availability partition ", count: 400)
        let documents = (0..<8).map { document("Notes/n\($0).md", category: .notes, text: big) }
        let budget = WorkspaceContextBudget(totalCharacters: 2_000, perDocumentCharacters: 600, maxDocuments: 4, maxJournalEntries: 2, journalEntryCharacters: 200)
        let brief = WorkspaceContextComposer(budget: budget).compose(workspace: workspace, documents: documents, journal: [], question: "consistency tradeoffs")
        XCTAssertLessThanOrEqual(brief.text.count, 2_600, "small overshoot from headers is fine, runaway growth is not")
        XCTAssertLessThanOrEqual(brief.documentCount, 4)
    }

    func testExcerptPicksTheParagraphMatchingTheQuestion() {
        let text = ["Intro about the company culture.", "We rebuilt the ledger on Kafka with idempotent consumers.", "Closing notes about benefits."].joined(separator: "\n\n")
        let excerpt = WorkspaceRelevanceRanker.excerpt(from: text, question: "kafka idempotent", maxCharacters: 60)
        XCTAssertTrue(excerpt.contains("Kafka"))
        XCTAssertFalse(excerpt.contains("benefits"))
    }

    func testJournalShelfFilesAreNotRankedAsDocuments() {
        let mirror = document("Journal/2026-09-02.md", category: .journal, text: "Idempotency keys: store request hash keyed by client id.")
        XCTAssertTrue(WorkspaceRelevanceRanker.rankDocuments([mirror], question: "idempotency").isEmpty)
    }

    func testDocumentsWithoutTextAreNeverRanked() {
        let image = WorkspaceDocument(workspaceID: workspace.id, relativePath: "Notes/a.png", kind: .image, category: .notes, byteSize: 1, sha256: "a")
        XCTAssertTrue(WorkspaceRelevanceRanker.rankDocuments([image], question: "anything").isEmpty)
    }
}
