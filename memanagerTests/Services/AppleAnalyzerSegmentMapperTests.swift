import XCTest
@testable import memanager

/// Freezes the mapping contract between analyzer results and the
/// `DeepgramTranscriptSegment` DTO the merger consumes.
final class AppleAnalyzerSegmentMapperTests: XCTestCase {
    func testMicSegmentsCarryNoSpeakerID() {
        let mapper = AppleAnalyzerSegmentMapper(source: .microphone)
        let segment = mapper.segment(
            text: "hello there",
            confidence: 0.9,
            startSeconds: 1.5,
            endSeconds: 2.25,
            isFinal: true
        )
        XCTAssertNil(segment.speaker, "Merger labels mic finals as 'me'; a speaker id would break that")
        XCTAssertEqual(segment.text, "hello there")
        XCTAssertEqual(segment.startTime, 1.5)
        XCTAssertEqual(segment.endTime, 2.25)
        XCTAssertTrue(segment.isFinal)
        XCTAssertEqual(segment.confidence, 0.9)
        XCTAssertTrue(segment.words.isEmpty)
    }

    func testSystemSegmentsUseConstantSpeakerZero() {
        let mapper = AppleAnalyzerSegmentMapper(source: .systemAudio)
        let segment = mapper.segment(
            text: "question from the interviewer",
            confidence: nil,
            startSeconds: 0,
            endSeconds: 3,
            isFinal: false
        )
        XCTAssertEqual(segment.speaker, 0, "System audio maps to the first numbered display speaker")
        XCTAssertFalse(segment.isFinal)
        XCTAssertNil(segment.confidence)
    }

    func testNonFiniteAndNegativeTimesAreSanitized() {
        let mapper = AppleAnalyzerSegmentMapper(source: .microphone)
        let nanStart = mapper.segment(
            text: "x", confidence: nil,
            startSeconds: Double.nan, endSeconds: -2, isFinal: true
        )
        XCTAssertEqual(nanStart.startTime, 0)
        XCTAssertEqual(nanStart.endTime, 0)

        let inverted = mapper.segment(
            text: "x", confidence: nil,
            startSeconds: 5, endSeconds: 1, isFinal: true
        )
        XCTAssertEqual(inverted.startTime, 5)
        XCTAssertEqual(inverted.endTime, 5, "End never precedes start")
    }

    func testConfidenceIsClampedToUnitInterval() {
        let mapper = AppleAnalyzerSegmentMapper(source: .microphone)
        XCTAssertEqual(
            mapper.segment(text: "x", confidence: 1.7, startSeconds: 0, endSeconds: 0, isFinal: true).confidence,
            1.0
        )
        XCTAssertEqual(
            mapper.segment(text: "x", confidence: -0.3, startSeconds: 0, endSeconds: 0, isFinal: true).confidence,
            0.0
        )
        XCTAssertNil(
            mapper.segment(text: "x", confidence: .infinity, startSeconds: 0, endSeconds: 0, isFinal: true).confidence
        )
    }
}
