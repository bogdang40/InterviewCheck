import XCTest
@testable import memanager

/// Wording of the diagnostics panel values.
final class DiagnosticsValueFormatterTests: XCTestCase {
    func testBoolAndMissingValues() {
        XCTAssertEqual(DiagnosticsValueFormatter.bool(true), "true")
        XCTAssertEqual(DiagnosticsValueFormatter.bool(false), "false")
        XCTAssertEqual(DiagnosticsValueFormatter.timestamp(nil), "n/a")
        XCTAssertEqual(DiagnosticsValueFormatter.timeAgo(nil), "n/a")
    }

    func testTimeAgoAndBufferSummary() {
        let now = Date(timeIntervalSince1970: 1_000)
        let earlier = now.addingTimeInterval(-2.5)
        XCTAssertEqual(DiagnosticsValueFormatter.timeAgo(earlier, now: now), "2.5s ago")
        XCTAssertEqual(DiagnosticsValueFormatter.buffer(count: 12, last: earlier, now: now), "12, 2.5s ago")
        XCTAssertEqual(DiagnosticsValueFormatter.buffer(count: 0, last: nil, now: now), "0, n/a")
    }

    func testNumericFormats() {
        XCTAssertEqual(DiagnosticsValueFormatter.decimal(0.4567), "0.46")
        XCTAssertEqual(DiagnosticsValueFormatter.decimal(-31.26, places: 1), "-31.3")
        XCTAssertEqual(DiagnosticsValueFormatter.gain(1.5), "1.50x")
    }

    func testEnumLabels() {
        XCTAssertEqual(DiagnosticsValueFormatter.authorization(.authorized), "authorized")
        XCTAssertEqual(DiagnosticsValueFormatter.speechAuthorization(.notDetermined), "notDetermined")
        XCTAssertEqual(DiagnosticsValueFormatter.deepgram(.error("boom")), "error (boom)")
        XCTAssertEqual(DiagnosticsValueFormatter.accessKey(.notConfigured), "notConfigured")
        XCTAssertEqual(DiagnosticsValueFormatter.sessionState(.paused), "paused")
    }

    func testGroupModelDefaults() {
        let group = DiagnosticsGroup(title: "Audio", systemImage: "waveform", rows: [DiagnosticsRow(label: "a", value: "b")], startsCollapsed: true)
        XCTAssertEqual(group.id, "Audio")
        XCTAssertTrue(group.startsCollapsed)
        XCTAssertFalse(DiagnosticsGroup(title: "Session", systemImage: "x", rows: []).startsCollapsed)
    }
}
