import XCTest
@testable import memanager

final class TranscriptionCredentialGateTests: XCTestCase {
    func testPendingAndUnavailableCredentialsCannotSelectFallbackEngine() {
        for status in [CredentialStatus.loading, .saving, .unavailable("Locked"), .saveFailed("Denied")] {
            XCTAssertNotNil(AudioCaptureService.transcriptionCredentialIssue(
                forceAppleSpeech: false, analyzerReady: false, deepgramStatus: status
            ))
        }
    }

    func testKnownPresenceAndAbsenceAllowNormalEngineSelection() {
        for status in [CredentialStatus.configured, .missing] {
            XCTAssertNil(AudioCaptureService.transcriptionCredentialIssue(
                forceAppleSpeech: false, analyzerReady: false, deepgramStatus: status
            ))
        }
    }

    func testExplicitLocalEngineDoesNotRequireCloudCredential() {
        for flags in [(true, false), (false, true), (true, true)] {
            XCTAssertNil(AudioCaptureService.transcriptionCredentialIssue(
                forceAppleSpeech: flags.0, analyzerReady: flags.1, deepgramStatus: .unavailable("Locked")
            ))
        }
    }
}
