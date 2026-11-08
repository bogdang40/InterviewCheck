import Foundation

enum WorkspaceJournalKind: String, Codable, CaseIterable, Identifiable {
    case problemSolved
    case note
    case interviewRound
    case decision
    case question

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .problemSolved: return "Problem Solved"
        case .note: return "Note"
        case .interviewRound: return "Interview Round"
        case .decision: return "Decision"
        case .question: return "Open Question"
        }
    }

    var systemImage: String {
        switch self {
        case .problemSolved: return "checkmark.seal"
        case .note: return "pencil.line"
        case .interviewRound: return "person.wave.2"
        case .decision: return "signpost.right"
        case .question: return "questionmark.bubble"
        }
    }
}

/// The running log of a job pursuit. Problem solved entries are appended
/// automatically after Quick Assist turns while a workspace is active, so
/// the next turn can build on what was already worked through.
struct WorkspaceJournalEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let workspaceID: UUID
    var kind: WorkspaceJournalKind
    var title: String
    var body: String
    var sessionID: String?
    var threadID: String?
    var turnID: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        kind: WorkspaceJournalKind,
        title: String,
        body: String,
        sessionID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.threadID = threadID
        self.turnID = turnID
        self.createdAt = createdAt
    }
}
