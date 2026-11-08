import XCTest
@testable import memanager

/// Pure presentation rules behind the Workspaces screen: tones, row
/// subtitles, document states, shelf grouping, tags, bind messages, and
/// selection.
final class WorkspacePresentationTests: XCTestCase {
    func testStageTonesHighlightTheHotPipeline() {
        XCTAssertEqual(WorkspaceStatusPresentation.tone(for: .interviewing), .info)
        XCTAssertEqual(WorkspaceStatusPresentation.tone(for: .offer), .success)
        XCTAssertEqual(WorkspaceStatusPresentation.tone(for: .applied), .neutral)
        XCTAssertEqual(WorkspaceStatusPresentation.tone(for: .researching), .neutral)
        XCTAssertEqual(WorkspaceStatusPresentation.tone(for: .closed), .neutral)
    }

    func testArchivedRowsReadArchivedAndFade() {
        var workspace = JobWorkspace(name: "A", company: "Acme", role: "SWE", folderPath: "/tmp/a")
        XCTAssertEqual(WorkspaceStatusPresentation.subtitle(for: workspace), "SWE at Acme")
        XCTAssertEqual(WorkspaceStatusPresentation.rowOpacity(isArchived: false), 1)
        workspace.isArchived = true
        XCTAssertEqual(WorkspaceStatusPresentation.subtitle(for: workspace), "Archived")
        XCTAssertLessThan(WorkspaceStatusPresentation.rowOpacity(isArchived: true), 1)
    }

    func testJournalKindTones() {
        XCTAssertEqual(WorkspaceJournalKindPresentation.tone(for: .problemSolved), .success)
        XCTAssertEqual(WorkspaceJournalKindPresentation.tone(for: .interviewRound), .info)
        XCTAssertEqual(WorkspaceJournalKindPresentation.tone(for: .question), .warning)
        XCTAssertEqual(WorkspaceJournalKindPresentation.tone(for: .decision), .neutral)
        XCTAssertEqual(WorkspaceJournalKindPresentation.tone(for: .note), .neutral)
    }

    func testDocumentIndexStateResolution() {
        let workspaceID = UUID()
        func document(kind: WorkspaceDocumentKind, text: String?, truncated: Bool = false) -> WorkspaceDocument {
            WorkspaceDocument(
                workspaceID: workspaceID,
                relativePath: "Notes/a.md",
                kind: kind,
                category: .notes,
                byteSize: 10,
                sha256: "x",
                extractedText: text,
                extractedTruncated: truncated
            )
        }
        XCTAssertEqual(WorkspaceDocumentIndexState.resolve(document(kind: .markdown, text: "hello")), .indexed)
        XCTAssertEqual(WorkspaceDocumentIndexState.resolve(document(kind: .pdf, text: "hello", truncated: true)), .truncated)
        XCTAssertEqual(WorkspaceDocumentIndexState.resolve(document(kind: .text, text: "   ")), .noText)
        XCTAssertEqual(WorkspaceDocumentIndexState.resolve(document(kind: .image, text: nil)), .skipped)
        XCTAssertEqual(WorkspaceDocumentIndexState.indexed.tone, .success)
        XCTAssertEqual(WorkspaceDocumentIndexState.truncated.tone, .warning)
        XCTAssertEqual(WorkspaceDocumentIndexState.noText.tone, .warning)
        XCTAssertEqual(WorkspaceDocumentIndexState.skipped.tone, .neutral)
    }

    func testShelvesFollowPromptPriorityAndDropEmptyOnes() {
        let workspaceID = UUID()
        func document(_ path: String, _ category: WorkspaceDocumentCategory) -> WorkspaceDocument {
            WorkspaceDocument(workspaceID: workspaceID, relativePath: path, kind: .markdown, category: category, byteSize: 1, sha256: path)
        }
        let shelves = WorkspaceDocumentShelves.group([
            document("Notes/n.md", .notes),
            document("Projects/p.md", .projects),
            document("Job Description/jd.md", .jobDescription),
            document("Notes/m.md", .notes)
        ])
        XCTAssertEqual(shelves.map(\.category), [.jobDescription, .projects, .notes])
        XCTAssertEqual(shelves[2].documents.map(\.relativePath), ["Notes/n.md", "Notes/m.md"])
        XCTAssertTrue(WorkspaceDocumentShelves.group([]).isEmpty)
    }

    func testTagsCodecRoundTripsAndDropsBlanks() {
        XCTAssertEqual(WorkspaceTagsCodec.decode(" payments,  go ,, "), ["payments", "go"])
        XCTAssertEqual(WorkspaceTagsCodec.encode(["payments", "go"]), "payments, go")
        XCTAssertEqual(WorkspaceTagsCodec.decode(WorkspaceTagsCodec.encode(["a", "b"])), ["a", "b"])
        XCTAssertEqual(WorkspaceTagsCodec.decode(""), [])
    }

    func testBindMessagesCarryTheirTone() {
        XCTAssertEqual(WorkspaceBindMessageResolver.message(for: .bound).tone, .success)
        XCTAssertEqual(WorkspaceBindMessageResolver.message(for: .noActiveMode).tone, .warning)
        XCTAssertEqual(WorkspaceBindMessageResolver.message(for: .folderUnavailable).tone, .critical)
        XCTAssertFalse(WorkspaceBindMessageResolver.message(for: .bound).text.isEmpty)
    }

    func testSelectionPrefersCurrentThenActiveThenFirst() {
        let first = JobWorkspace(name: "First", folderPath: "/tmp/1")
        let active = JobWorkspace(name: "Active", folderPath: "/tmp/2")
        let sorted = [first, active]
        XCTAssertEqual(WorkspaceSelectionResolver.resolve(current: active.id, active: first.id, sorted: sorted), active.id)
        XCTAssertEqual(WorkspaceSelectionResolver.resolve(current: UUID(), active: active.id, sorted: sorted), active.id)
        XCTAssertEqual(WorkspaceSelectionResolver.resolve(current: nil, active: nil, sorted: sorted), first.id)
        XCTAssertNil(WorkspaceSelectionResolver.resolve(current: nil, active: nil, sorted: []))
    }
}
