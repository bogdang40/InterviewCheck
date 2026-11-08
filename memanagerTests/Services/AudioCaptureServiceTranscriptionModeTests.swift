import XCTest
import CoreAudio
@testable import memanager

final class AudioCaptureServiceTranscriptionModeTests: XCTestCase {
    func testLegacyModeAutoSwitchesWhenInputIsBluetooth() {
        let shouldSwitch = AudioCaptureService.shouldAutoSwitchLegacyDeepgramToSourceBased(
            useSourceBasedPreference: false,
            inputTransport: .bluetoothHFP,
            outputTransport: .builtIn
        )

        XCTAssertTrue(shouldSwitch)
    }

    func testLegacyModeAutoSwitchesWhenOutputIsBluetooth() {
        let shouldSwitch = AudioCaptureService.shouldAutoSwitchLegacyDeepgramToSourceBased(
            useSourceBasedPreference: false,
            inputTransport: .builtIn,
            outputTransport: .bluetoothLE
        )

        XCTAssertTrue(shouldSwitch)
    }

    func testLegacyModeDoesNotAutoSwitchOnNonBluetoothRoute() {
        let shouldSwitch = AudioCaptureService.shouldAutoSwitchLegacyDeepgramToSourceBased(
            useSourceBasedPreference: false,
            inputTransport: .builtIn,
            outputTransport: .usb
        )

        XCTAssertFalse(shouldSwitch)
    }

    func testSourceBasedPreferenceNeverAutoSwitches() {
        let shouldSwitch = AudioCaptureService.shouldAutoSwitchLegacyDeepgramToSourceBased(
            useSourceBasedPreference: true,
            inputTransport: .bluetoothHFP,
            outputTransport: .bluetoothLE
        )

        XCTAssertFalse(shouldSwitch)
    }
}
