import Foundation
@testable import memanager

/// Realistic models for the Workspaces and Knowledge render smoke tests: a
/// workspace mid loop with indexed files and journal entries, and a fact
/// with two relations.
enum WorkspacesKnowledgeRenderFixtures {
    static let workspace = JobWorkspace(
        name: "Stripe Staff Engineer",
        company: "Stripe",
        role: "Staff Engineer, Payments",
        status: .interviewing,
        folderPath: "/Users/abe/Documents/memanager Workspaces/Stripe Staff Engineer",
        jobDescriptionSummary: "Own the payments ledger, lead a team of four, ship in Go and Ruby.",
        notes: "Recruiter is Maya. Onsite is a five round loop.",
        tags: ["payments", "go", "distributed systems"]
    )

    static var documents: [WorkspaceDocument] {
        let id = workspace.id
        return [
            WorkspaceDocument(workspaceID: id, relativePath: "Job Description/Staff Engineer Payments.pdf", kind: .pdf, category: .jobDescription, byteSize: 184_320, sha256: "a", extractedText: "text"),
            WorkspaceDocument(workspaceID: id, relativePath: "Resume/Abe Khadra Stripe.pdf", kind: .pdf, category: .resume, byteSize: 96_512, sha256: "b", extractedText: "text", extractedTruncated: true),
            WorkspaceDocument(workspaceID: id, relativePath: "Projects/Ledger migration.md", kind: .markdown, category: .projects, byteSize: 12_288, sha256: "c", extractedText: "text"),
            WorkspaceDocument(workspaceID: id, relativePath: "Interviews/Round one.txt", kind: .text, category: .interviews, byteSize: 2_048, sha256: "d", extractedText: nil),
            WorkspaceDocument(workspaceID: id, relativePath: "Notes/Whiteboard.png", kind: .image, category: .notes, byteSize: 1_048_576, sha256: "e")
        ]
    }

    static var journal: [WorkspaceJournalEntry] {
        let id = workspace.id
        return [
            WorkspaceJournalEntry(
                workspaceID: id,
                kind: .problemSolved,
                title: "Idempotent retries for the ledger writer",
                body: "Walked through a dedupe key per request and a bounded retry with jitter. The interviewer wanted the failure mode when the key store is down.",
                createdAt: Date().addingTimeInterval(-3_600)
            ),
            WorkspaceJournalEntry(
                workspaceID: id,
                kind: .interviewRound,
                title: "Round two with the payments team",
                body: "System design on settlement batching.",
                createdAt: Date().addingTimeInterval(-86_400)
            ),
            WorkspaceJournalEntry(
                workspaceID: id,
                kind: .question,
                title: "Ask about the on call rotation",
                body: "Unclear whether staff engineers carry the pager.",
                createdAt: Date().addingTimeInterval(-172_800)
            )
        ]
    }

    static let indexReport = WorkspaceIndexReport(scanned: 5, updated: 4, removed: 0, skipped: 1, failures: [])

    static var knowledgeDetail: KnowledgeNodeDetailModel {
        let center = KnowledgeNode(
            kind: .project,
            label: "Ledger migration",
            summary: "Moved the payments ledger from a monolith table to an append only event store with nightly reconciliation.",
            properties: ["team": "Payments", "year": "2024", "scale": "40k events per second"],
            sourceKind: .manual,
            mentionCount: 4
        )
        let skill = KnowledgeNode(kind: .skill, label: "Go", summary: "Primary language since 2019.", mentionCount: 7)
        let person = KnowledgeNode(kind: .person, label: "Maya Chen", summary: "Engineering manager on the payments team.")
        let edges = [
            KnowledgeEdge(fromNodeID: center.id, toNodeID: skill.id, relation: .usedSkill, weight: 1.4, evidence: "resume"),
            KnowledgeEdge(fromNodeID: person.id, toNodeID: center.id, relation: .workedWith, evidence: "round two notes")
        ]
        return KnowledgeNodeDetailModel(
            node: center,
            neighborhood: KnowledgeSubgraph(nodes: [center, skill, person], edges: edges),
            linkCandidates: [center, skill, person]
        )
    }
}
