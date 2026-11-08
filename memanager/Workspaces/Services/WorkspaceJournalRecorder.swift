import Foundation

/// Turns a finished Quick Assist turn into a durable "problem solved" entry:
/// one row for retrieval and one markdown append in `Journal/` so the log
/// survives outside the app.
final class WorkspaceJournalRecorder {
    static let maxBodyCharacters = 1_800
    static let maxTitleCharacters = 120

    private let database: SessionDatabase
    private let fileManager: FileManager

    init(database: SessionDatabase = .shared, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
    }

    @discardableResult
    func recordProblemSolved(
        workspace: JobWorkspace,
        question: String,
        response: String,
        sessionID: String?,
        threadID: String?,
        turnID: String?,
        now: Date = Date()
    ) -> WorkspaceJournalEntry? {
        let title = WorkspaceJournalRecorder.title(fromQuestion: question, response: response)
        let body = WorkspaceJournalRecorder.condense(response)
        guard !body.isEmpty else { return nil }
        let entry = WorkspaceJournalEntry(
            workspaceID: workspace.id,
            kind: .problemSolved,
            title: title,
            body: body,
            sessionID: sessionID,
            threadID: threadID,
            turnID: turnID,
            createdAt: now
        )
        return persist(entry, in: workspace)
    }

    @discardableResult
    func record(_ entry: WorkspaceJournalEntry, in workspace: JobWorkspace) -> WorkspaceJournalEntry? {
        persist(entry, in: workspace)
    }

    /// The editor needs the underlying persistence failure to retain its draft.
    func recordManualEntry(_ entry: WorkspaceJournalEntry, in workspace: JobWorkspace) throws -> String? {
        try database.insertWorkspaceJournalEntry(entry)
        return appendMarkdown(entry, in: workspace)
    }

    private func persist(_ entry: WorkspaceJournalEntry, in workspace: JobWorkspace) -> WorkspaceJournalEntry? {
        do {
            try database.insertWorkspaceJournalEntry(entry)
        } catch {
            NSLog("[WorkspaceJournalRecorder] insert failed: \(error.localizedDescription)")
            return nil
        }
        appendMarkdown(entry, in: workspace)
        return entry
    }

    // MARK: - Markdown mirror

    @discardableResult
    private func appendMarkdown(_ entry: WorkspaceJournalEntry, in workspace: JobWorkspace) -> String? {
        let journalDirectory = workspace.folderURL.appendingPathComponent(WorkspaceDocumentCategory.journal.folderName, isDirectory: true)
        guard fileManager.fileExists(atPath: workspace.folderURL.path) else { return "The workspace folder is missing." }
        let fileURL = journalDirectory.appendingPathComponent(WorkspaceJournalRecorder.fileName(for: entry.createdAt))
        let block = WorkspaceJournalRecorder.markdownBlock(for: entry)
        do {
            try fileManager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path) {
                // Throwing FileHandle API only: the legacy write(_:) raises an
                // uncatchable exception on a full or read only volume.
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(block.utf8))
            } else {
                let header = "# Journal \(WorkspaceJournalRecorder.dayFormatter.string(from: entry.createdAt))\n"
                try (header + block).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            return nil
        } catch {
            NSLog("[WorkspaceJournalRecorder] markdown append failed: %@", error.localizedDescription)
            return error.localizedDescription
        }
    }

    static func fileName(for date: Date) -> String {
        "\(dayFormatter.string(from: date)).md"
    }

    static func markdownBlock(for entry: WorkspaceJournalEntry) -> String {
        let time = timeFormatter.string(from: entry.createdAt)
        return "\n## \(time) \(entry.kind.displayName): \(entry.title)\n\n\(entry.body)\n"
    }

    // MARK: - Text shaping

    static func title(fromQuestion question: String, response: String) -> String {
        let candidate = firstMeaningfulLine(of: question) ?? firstMeaningfulLine(of: response) ?? "Problem worked through"
        return String(candidate.prefix(maxTitleCharacters))
    }

    static func condense(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxBodyCharacters else { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: maxBodyCharacters)
        let head = trimmed[..<cut]
        if let lastBreak = head.lastIndex(where: { $0 == "\n" || $0 == "." }), head.distance(from: head.startIndex, to: lastBreak) > maxBodyCharacters / 2 {
            return String(head[...lastBreak]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n(condensed)"
        }
        return String(head).trimmingCharacters(in: .whitespacesAndNewlines) + " (condensed)"
    }

    private static func firstMeaningfulLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#*->"))) }
            .first { $0.count >= 6 }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
