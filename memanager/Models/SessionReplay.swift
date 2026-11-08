import AppKit
import Foundation

struct SessionReplaySnapshot: Identifiable {
    let record: SessionSnapshotRecord
    let image: NSImage?

    var id: String { record.id }
}

struct SessionReplayTurnEvidence {
    let call: QuickAssistCallRecord
    let toolCalls: [SessionToolCallRecord]
}

struct SessionReplay {
    let session: SessionRecord?
    let events: [WorkstreamTimelineEvent]
    let snapshots: [SessionReplaySnapshot]
    let turns: [SessionReplayTurnEvidence]
    let transcriptEntries: [TranscriptEntryRecord]
    let coachFindings: [CoachFindingRecord]
    let debrief: SessionDebrief?
    let practiceCards: [PracticeCard]

    static let empty = SessionReplay(
        session: nil,
        events: [],
        snapshots: [],
        turns: [],
        transcriptEntries: [],
        coachFindings: [],
        debrief: nil,
        practiceCards: []
    )
}
