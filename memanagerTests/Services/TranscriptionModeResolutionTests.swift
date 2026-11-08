import XCTest
@testable import memanager

/// Pins the pure engine selection ladder:
/// force legacy dictation > free on device analyzer > Deepgram fallback > Apple Speech.
final class TranscriptionModeResolutionTests: XCTestCase {
    private typealias Mode = AudioCaptureService.TranscriptionMode

    private func resolve(
        forceAppleSpeech: Bool = false,
        analyzerReady: Bool = false,
        hasDeepgramKey: Bool = false,
        useSourceBasedPreference: Bool = false,
        autoSwitchLegacyToSourceBased: Bool = false
    ) -> Mode {
        AudioCaptureService.resolvePreferredTranscriptionMode(
            forceAppleSpeech: forceAppleSpeech,
            analyzerReady: analyzerReady,
            hasDeepgramKey: hasDeepgramKey,
            useSourceBasedPreference: useSourceBasedPreference,
            autoSwitchLegacyToSourceBased: autoSwitchLegacyToSourceBased
        )
    }

    func testAnalyzerWinsWheneverReady() {
        XCTAssertEqual(resolve(analyzerReady: true), .appleAnalyzer)
        XCTAssertEqual(
            resolve(analyzerReady: true, hasDeepgramKey: true, useSourceBasedPreference: true),
            .appleAnalyzer,
            "The free analyzer outranks a configured Deepgram key"
        )
    }

    func testForceAppleSpeechOverridesEverything() {
        XCTAssertEqual(
            resolve(forceAppleSpeech: true, analyzerReady: true, hasDeepgramKey: true),
            .appleSpeech
        )
    }

    func testNoAnalyzerNoKeyFallsBackToAppleSpeech() {
        XCTAssertEqual(resolve(), .appleSpeech)
    }

    func testDeepgramFallbackLadderPreserved() {
        XCTAssertEqual(
            resolve(hasDeepgramKey: true, useSourceBasedPreference: true),
            .deepgramSourceBased
        )
        XCTAssertEqual(
            resolve(hasDeepgramKey: true, autoSwitchLegacyToSourceBased: true),
            .deepgramSourceBased
        )
        XCTAssertEqual(resolve(hasDeepgramKey: true), .deepgramLegacy)
    }

    func testDualStreamTopologyFlags() {
        XCTAssertTrue(Mode.appleAnalyzer.usesDualStreamTopology)
        XCTAssertTrue(Mode.deepgramSourceBased.usesDualStreamTopology)
        XCTAssertFalse(Mode.deepgramLegacy.usesDualStreamTopology)
        XCTAssertFalse(Mode.appleSpeech.usesDualStreamTopology)
    }

    func testSystemAudioForcingFlags() {
        XCTAssertTrue(Mode.appleAnalyzer.forcesSystemAudioCapture)
        XCTAssertTrue(Mode.deepgramLegacy.forcesSystemAudioCapture)
        XCTAssertTrue(Mode.deepgramSourceBased.forcesSystemAudioCapture)
        XCTAssertFalse(Mode.appleSpeech.forcesSystemAudioCapture)
    }

    func testDeepgramFlagsExcludeAnalyzer() {
        XCTAssertFalse(Mode.appleAnalyzer.usesDeepgram)
        XCTAssertTrue(Mode.deepgramLegacy.usesDeepgram)
        XCTAssertTrue(Mode.deepgramSourceBased.usesDeepgram)
    }
}
