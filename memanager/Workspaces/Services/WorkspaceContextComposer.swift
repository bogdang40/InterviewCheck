import Foundation

/// Budget knobs for how much workspace material may enter one prompt.
struct WorkspaceContextBudget: Equatable {
    var totalCharacters: Int
    var perDocumentCharacters: Int
    var maxDocuments: Int
    var maxJournalEntries: Int
    var journalEntryCharacters: Int

    static let `default` = WorkspaceContextBudget(
        totalCharacters: 7_000,
        perDocumentCharacters: 1_800,
        maxDocuments: 4,
        maxJournalEntries: 4,
        journalEntryCharacters: 420
    )
}

struct WorkspaceContextBrief: Equatable {
    let workspaceID: UUID
    let text: String
    let documentCount: Int
    let journalCount: Int
}

/// Builds the "JOB WORKSPACE" block injected into Quick Assist prompts:
/// who the company is, what the role wants, what has been worked through,
/// and the most relevant excerpts for this exact question.
final class WorkspaceContextComposer {
    private let database: SessionDatabase
    private let budget: WorkspaceContextBudget

    init(database: SessionDatabase = .shared, budget: WorkspaceContextBudget = .default) {
        self.database = database
        self.budget = budget
    }

    func compose(workspace: JobWorkspace, question: String, now: Date = Date()) -> WorkspaceContextBrief {
        let documents = database.loadWorkspaceDocuments(workspaceID: workspace.id)
        let journal = database.loadWorkspaceJournal(workspaceID: workspace.id, limit: 60)
        return compose(workspace: workspace, documents: documents, journal: journal, question: question, now: now)
    }

    /// IO free variant used by tests and by callers that already hold the data.
    func compose(
        workspace: JobWorkspace,
        documents: [WorkspaceDocument],
        journal: [WorkspaceJournalEntry],
        question: String,
        now: Date = Date()
    ) -> WorkspaceContextBrief {
        var sections: [String] = [header(for: workspace)]
        var remaining = max(0, budget.totalCharacters - sections[0].count)

        if let summary = workspace.jobDescriptionSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            let allowance = max(0, min(remaining, budget.perDocumentCharacters))
            if allowance > 0 {
                let block = "Role summary:\n" + String(summary.prefix(allowance))
                sections.append(block)
                remaining = max(0, remaining - block.count)
            }
        }

        let rankedJournal = WorkspaceRelevanceRanker.rankJournal(journal, question: question, now: now).prefix(budget.maxJournalEntries)
        var journalLines: [String] = []
        for scored in rankedJournal where remaining > 200 {
            let body = String(scored.item.body.prefix(budget.journalEntryCharacters))
            let line = "- [\(scored.item.kind.displayName)] \(scored.item.title): \(body.replacingOccurrences(of: "\n", with: " "))"
            journalLines.append(line)
            remaining = max(0, remaining - line.count)
        }
        if !journalLines.isEmpty {
            sections.append("Already worked through for this job (most relevant first):\n" + journalLines.joined(separator: "\n"))
        }

        let rankedDocuments = WorkspaceRelevanceRanker.rankDocuments(documents, question: question).prefix(budget.maxDocuments)
        var documentCount = 0
        for scored in rankedDocuments where remaining > 300 {
            let allowance = min(budget.perDocumentCharacters, remaining - 100)
            let excerpt = WorkspaceRelevanceRanker.excerpt(from: scored.item.extractedText ?? "", question: question, maxCharacters: allowance)
            guard !excerpt.isEmpty else { continue }
            let block = "File \(scored.item.relativePath) (\(scored.item.category.displayName)):\n\(excerpt)"
            sections.append(block)
            remaining = max(0, remaining - block.count)
            documentCount += 1
        }

        let text = "JOB WORKSPACE CONTEXT:\n" + sections.joined(separator: "\n\n")
        return WorkspaceContextBrief(workspaceID: workspace.id, text: text, documentCount: documentCount, journalCount: journalLines.count)
    }

    /// Header fields are user typed and uncapped in the model, so each one is
    /// bounded here to keep the header from eating the whole budget.
    private static let headerFieldCharacters = 240

    private func header(for workspace: JobWorkspace) -> String {
        func bounded(_ value: String) -> String { String(value.prefix(WorkspaceContextComposer.headerFieldCharacters)) }
        var lines = ["Workspace: \(bounded(workspace.displayTitle))"]
        if !workspace.company.isEmpty { lines.append("Company: \(bounded(workspace.company))") }
        if !workspace.role.isEmpty { lines.append("Role: \(bounded(workspace.role))") }
        lines.append("Stage: \(workspace.status.displayName)")
        if !workspace.tags.isEmpty { lines.append("Tags: \(bounded(workspace.tags.joined(separator: ", ")))") }
        let notes = workspace.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines.append("Notes: \(String(notes.prefix(400)))") }
        return lines.joined(separator: "\n")
    }
}
