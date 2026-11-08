import Foundation

/// Live progress event emitted by `ProjectToolLoopRunner` as tools fire during
/// a turn. The UI subscribes to these to render per call spinner cards.
/// Each tool call emits exactly one `.started` event followed by one of
/// `.completed` or `.failed`, all carrying the same `callID`.
enum ProjectToolCallPhase: Equatable, Sendable {
    case started
    case completed
    case failed
}

/// Live reasoning fragment emitted by `ProjectToolLoopRunner` as the model
/// narrates its intent before or between tool calls. The UI weaves these
/// between the tool cards so the experience reads as a train of thought.
struct ProjectToolReasoningEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let iteration: Int
    let text: String
    let precedesCallID: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        iteration: Int,
        text: String,
        precedesCallID: String?,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.iteration = iteration
        self.text = text
        self.precedesCallID = precedesCallID
        self.timestamp = timestamp
    }
}

struct ProjectToolCallEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let callID: String
    let toolName: String
    let displayInput: String
    let rawArgumentsJSON: String
    let phase: ProjectToolCallPhase
    let startedAt: Date
    let completedAt: Date?
    let durationMs: Int?
    let resultContent: String?
    let contentTruncated: Bool
    let overflowPath: String?
    let referencedPaths: [String]
    let isError: Bool

    var argumentsPreview: String {
        String(displayInput.prefix(120))
    }

    var outputPreview: String? {
        guard let resultContent else { return nil }
        return String(resultContent.prefix(240))
    }

    static func started(
        callID: String,
        toolName: String,
        displayInput: String,
        rawArgumentsJSON: String,
        startedAt: Date
    ) -> ProjectToolCallEvent {
        ProjectToolCallEvent(
            id: UUID(),
            callID: callID,
            toolName: toolName,
            displayInput: displayInput,
            rawArgumentsJSON: rawArgumentsJSON,
            phase: .started,
            startedAt: startedAt,
            completedAt: nil,
            durationMs: nil,
            resultContent: nil,
            contentTruncated: false,
            overflowPath: nil,
            referencedPaths: [],
            isError: false
        )
    }

    static func finished(
        callID: String,
        toolName: String,
        displayInput: String,
        rawArgumentsJSON: String,
        startedAt: Date,
        completedAt: Date,
        resultContent: String,
        contentTruncated: Bool,
        overflowPath: String?,
        referencedPaths: [String],
        isError: Bool
    ) -> ProjectToolCallEvent {
        ProjectToolCallEvent(
            id: UUID(),
            callID: callID,
            toolName: toolName,
            displayInput: displayInput,
            rawArgumentsJSON: rawArgumentsJSON,
            phase: isError ? .failed : .completed,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: Int(completedAt.timeIntervalSince(startedAt) * 1000),
            resultContent: resultContent,
            contentTruncated: contentTruncated,
            overflowPath: overflowPath,
            referencedPaths: referencedPaths,
            isError: isError
        )
    }
}
