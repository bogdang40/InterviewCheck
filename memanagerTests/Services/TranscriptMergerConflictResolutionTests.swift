import XCTest
@testable import memanager

final class TranscriptMergerConflictResolutionTests: XCTestCase {
    func testMicThenSystemDuplicateKeepsSystemWithRetroactiveCorrection() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: true, threshold: 0.62, timeWindow: 3.0)

        let base = Date()
        merger.appendMicTranscript(
            makeSegment(text: "hello from remote user", speaker: nil, confidence: 0.80),
            streamStart: base,
            receivedAt: base
        )

        merger.appendSystemTranscript(
            makeSegment(text: "hello from remote user", speaker: 7, confidence: 0.90),
            streamStart: base,
            receivedAt: base.addingTimeInterval(0.3)
        )

        XCTAssertEqual(merger.fullTranscript, "Speaker 1: hello from remote user")

        let stats = merger.conflictStatsSnapshot
        XCTAssertEqual(stats.micDuplicatesSuppressed, 0)
        XCTAssertEqual(stats.systemDuplicatesSuppressed, 0)
        XCTAssertEqual(stats.retroactiveCorrections, 1)
        XCTAssertEqual(stats.lastDecision, "keep_system")
    }

    func testSystemThenMicDuplicateDropsMic() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: true, threshold: 0.62, timeWindow: 3.0)

        let base = Date()
        merger.appendSystemTranscript(
            makeSegment(text: "this is the remote response", speaker: 3, confidence: 0.92),
            streamStart: base,
            receivedAt: base
        )

        merger.appendMicTranscript(
            makeSegment(text: "this is the remote response", speaker: nil, confidence: 0.80),
            streamStart: base,
            receivedAt: base.addingTimeInterval(0.2)
        )

        XCTAssertEqual(merger.fullTranscript, "Speaker 1: this is the remote response")

        let stats = merger.conflictStatsSnapshot
        XCTAssertEqual(stats.micDuplicatesSuppressed, 1)
        XCTAssertEqual(stats.systemDuplicatesSuppressed, 0)
        XCTAssertEqual(stats.retroactiveCorrections, 0)
        XCTAssertEqual(stats.lastDecision, "keep_system")
    }

    func testLowConfidenceSystemDuplicateKeepsMic() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: true, threshold: 0.62, timeWindow: 3.0)

        let base = Date()
        merger.appendMicTranscript(
            makeSegment(text: "i think this answer works", speaker: nil, confidence: 0.95),
            streamStart: base,
            receivedAt: base
        )

        merger.appendSystemTranscript(
            makeSegment(text: "i think this answer works", speaker: 1, confidence: 0.70),
            streamStart: base,
            receivedAt: base.addingTimeInterval(0.2)
        )

        XCTAssertEqual(merger.fullTranscript, "Me: i think this answer works")

        let stats = merger.conflictStatsSnapshot
        XCTAssertEqual(stats.micDuplicatesSuppressed, 0)
        XCTAssertEqual(stats.systemDuplicatesSuppressed, 1)
        XCTAssertEqual(stats.retroactiveCorrections, 0)
        XCTAssertEqual(stats.lastDecision, "keep_mic")
    }

    func testDisablingEchoFilterPreservesMatchingSpeechFromBothSources() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: false, threshold: 0.62, timeWindow: 3.0)
        let base = Date()
        merger.appendSystemTranscript(
            makeSegment(text: "the repeated phrase is intentional", speaker: 3, confidence: 0.9),
            streamStart: base, receivedAt: base
        )
        merger.appendMicTranscript(
            makeSegment(text: "the repeated phrase is intentional", speaker: nil, confidence: 0.9),
            streamStart: base, receivedAt: base.addingTimeInterval(0.2)
        )
        XCTAssertEqual(merger.fullTranscript.split(separator: "\n").count, 2)
        XCTAssertEqual(merger.conflictStatsSnapshot.micDuplicatesSuppressed, 0)
        XCTAssertEqual(merger.conflictStatsSnapshot.retroactiveCorrections, 0)
    }

    func testDistinctUtterancesRemainSeparate() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: true, threshold: 0.62, timeWindow: 3.0)

        let base = Date()
        merger.appendMicTranscript(
            makeSegment(text: "my short update for the team", speaker: nil, confidence: 0.94),
            streamStart: base,
            receivedAt: base
        )

        merger.appendSystemTranscript(
            makeSegment(text: "thanks lets move to the next item", speaker: 4, confidence: 0.93),
            streamStart: base,
            receivedAt: base.addingTimeInterval(0.4)
        )

        let lines = merger.fullTranscript.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains("Me: my short update for the team"))
        XCTAssertTrue(lines.contains("Speaker 1: thanks lets move to the next item"))
    }

    func testEpochResetClearsSystemConflictHistory() {
        let merger = TranscriptMerger()
        merger.configureEchoFilter(enabled: false, threshold: 0.62, timeWindow: 3.0)

        let base = Date()
        merger.appendSystemTranscript(
            makeSegment(text: "shared phrase from remote", speaker: 2, confidence: 0.90),
            streamStart: base,
            receivedAt: base
        )

        merger.beginSystemStreamEpoch(resetPartials: true)

        merger.appendMicTranscript(
            makeSegment(text: "shared phrase from remote", speaker: nil, confidence: 0.90),
            streamStart: base,
            receivedAt: base.addingTimeInterval(0.4)
        )

        let lines = merger.fullTranscript.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let stats = merger.conflictStatsSnapshot
        XCTAssertEqual(stats.lastDecision, "epoch_reset_system")
    }

    func testConsolidationHonorsTwoSecondGap() {
        let merger = TranscriptMerger()

        let base = Date()
        merger.appendMicTranscript(
            makeSegment(text: "first chunk", speaker: nil, confidence: 0.95, start: 0),
            streamStart: base,
            receivedAt: base
        )

        merger.appendMicTranscript(
            makeSegment(text: "second chunk", speaker: nil, confidence: 0.95, start: 3),
            streamStart: base,
            receivedAt: base.addingTimeInterval(3)
        )

        let lines = merger.fullTranscript.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Me: first chunk")
        XCTAssertEqual(lines[1], "Me: second chunk")
    }
}

private extension TranscriptMergerConflictResolutionTests {
    func makeSegment(
        text: String,
        speaker: Int?,
        confidence: Double?,
        start: Double = 0
    ) -> DeepgramTranscriptSegment {
        DeepgramTranscriptSegment(
            text: text,
            speaker: speaker,
            startTime: start,
            endTime: start + 0.6,
            isFinal: true,
            confidence: confidence,
            words: []
        )
    }
}
