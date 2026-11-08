import Foundation

// MARK: - Session Mode Snapshot Record

/// Persistent representation of a `SessionModeSnapshot` row in SQLite.
struct SessionModeSnapshotRecord {
    let snapshotID: String
    let sessionID: String
    let sourceModeID: String?
    let capturedAt: Date
    let title: String
    let promptText: String
    let attachmentsJSON: String
    let projectFolderDisplayPath: String?
    let projectFolderEnabledAtCapture: Bool
    let createdAt: Date
}

// MARK: - Session Summary Record

struct SessionSummaryRecord {
    let sessionID: String
    var status: String
    var backgroundSummary: String
    var followUpEmail: String?
    var generatedAt: Date?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
}

struct SessionSummaryActionItemRecord {
    let id: String
    let sessionID: String
    let title: String
    let owner: String?
    let dueDate: String?
    let notes: String?
    let ordinal: Int
    let createdAt: Date
}

// MARK: - Tool Call Record

struct SessionToolCallRecord {
    let sessionID: String
    let threadID: String?
    let turnID: String?
    let toolName: String
    let argumentsJSON: String
    let displayInput: String?
    let resultPreview: String?
    let resultContent: String?
    let contentTruncated: Bool
    let overflowPath: String?
    let isError: Bool
    let iteration: Int
    let startedAt: Date
    var durationMs: Int?
}
