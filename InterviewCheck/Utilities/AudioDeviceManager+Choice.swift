import AVFoundation
import CoreAudio
import Foundation

/// The interviewer's choice of microphone (Settings › Audio). Stored by the
/// device's unique ID so it survives reconnects and restarts; when the chosen
/// device is missing the system default is used.
extension AudioDeviceManager {
    struct InputDevice: Identifiable, Equatable {
        let id: String      // CoreAudio device UID
        let deviceID: AudioDeviceID
        let name: String
    }

    static let preferredInputKey = "interviewcheck.audio.inputDeviceUID"

    static var preferredInputUID: String? {
        get { UserDefaults.standard.string(forKey: preferredInputKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferredInputKey) }
    }

    /// Live input devices, built-in first, then by name.
    static func inputDevices() -> [InputDevice] {
        availableInputDeviceIDs()
            .filter { deviceIsAlive($0) && deviceHasInputChannels($0) }
            .compactMap { id -> InputDevice? in
                guard let uid = deviceUID(for: id) else { return nil }
                return InputDevice(id: uid, deviceID: id, name: deviceName(for: id) ?? "Microphone")
            }
            .sorted { lhs, rhs in
                let lhsBuiltIn = transportType(for: lhs.deviceID) == .builtIn
                let rhsBuiltIn = transportType(for: rhs.deviceID) == .builtIn
                return lhsBuiltIn != rhsBuiltIn ? lhsBuiltIn : lhs.name < rhs.name
            }
    }

    /// The chosen microphone when it is connected; nil means system default.
    static func preferredInputDeviceID() -> AudioDeviceID? {
        guard let uid = preferredInputUID else { return nil }
        return inputDevices().first { $0.id == uid }?.deviceID
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr,
              let value = uid?.takeRetainedValue() else { return nil }
        return value as String
    }
}
