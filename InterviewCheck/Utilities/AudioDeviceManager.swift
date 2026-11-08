import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

// MARK: - Audio Transport Type

/// Represents the transport type of an audio device
enum AudioTransportType: UInt32, CustomStringConvertible {
    case unknown = 0
    case builtIn = 0x626C7464      // 'bltn' - kAudioDeviceTransportTypeBuiltIn
    case usb = 0x75736220          // 'usb ' - kAudioDeviceTransportTypeUSB
    case bluetoothHFP = 0x626C7566 // 'blue' - kAudioDeviceTransportTypeBluetooth (HFP)
    case bluetoothLE = 0x626C6C65  // 'blle' - kAudioDeviceTransportTypeBluetoothLE
    case virtual = 0x76697274      // 'virt' - kAudioDeviceTransportTypeVirtual
    case aggregate = 0x61706172    // 'apar' - kAudioDeviceTransportTypeAggregate

    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetoothHFP: return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .virtual: return "Virtual"
        case .aggregate: return "Aggregate"
        }
    }

    var isBluetooth: Bool {
        self == .bluetoothHFP || self == .bluetoothLE
    }
}

// MARK: - Audio Device Manager

enum AudioDeviceManager {

    private static func logDebug(_ message: String) {
        #if DEBUG
        print("[AudioDeviceManager] \(message)")
        #endif
    }

    static func resolvedOutputDeviceID() -> AudioDeviceID? {
        guard let outputID = defaultOutputDeviceID(),
              deviceIsAlive(outputID) else {
            return nil
        }
        return outputID
    }

    /// Get the human-readable name of an audio device.
    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &name
        )

        guard status == noErr else { return nil }
        return name as String
    }

    /// Get the transport type of an audio device.
    static func transportType(for deviceID: AudioDeviceID) -> AudioTransportType {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )

        guard status == noErr else { return .unknown }
        return AudioTransportType(rawValue: transportType) ?? .unknown
    }

    /// Check if a device is Bluetooth (HFP or LE).
    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        transportType(for: deviceID).isBluetooth
    }

    /// Log the current default input and output devices for debugging.
    static func logCurrentDevices() {
        if let inputID = resolvedInputDeviceID(),
           let inputName = deviceName(for: inputID) {
            logDebug("Current input device: \(inputName) (ID: \(inputID))")
        } else {
            logDebug("No input device available")
        }
        if let outputID = resolvedOutputDeviceID(),
           let outputName = deviceName(for: outputID) {
            logDebug("Current output device: \(outputName) (ID: \(outputID))")
        } else {
            logDebug("No output device available")
        }
    }

    /// Smart input device selection: matches input transport type to output.
    /// If output is Bluetooth, prefers Bluetooth input. Otherwise uses system default.
    static func smartInputDeviceID() -> AudioDeviceID? {
        // Check current output device
        guard let outputID = defaultOutputDeviceID() else {
            logDebug("Smart selection: No output device, using default input")
            return defaultInputDeviceID()
        }

        let outputTransport = transportType(for: outputID)

        // If output is Bluetooth, try to find matching Bluetooth input
        if outputTransport.isBluetooth {
            let bluetoothInput = availableInputDeviceIDs().first { deviceID in
                guard deviceIsAlive(deviceID), deviceHasInputChannels(deviceID) else { return false }
                let inputTransport = transportType(for: deviceID)
                return inputTransport.isBluetooth
            }

            if let bluetoothInput = bluetoothInput {
                let name = deviceName(for: bluetoothInput) ?? "Unknown Bluetooth"
                logDebug("Smart selection: Output is Bluetooth, selecting Bluetooth input: \(name)")
                return bluetoothInput
            } else {
                logDebug("Smart selection: Output is Bluetooth but no Bluetooth input found, using default")
            }
        }

        // Fall back to system default
        return defaultInputDeviceID()
    }

    // MARK: - Fallback Device Support

    /// Returns the built-in microphone device ID, if available.
    /// Used as fallback when Bluetooth or other devices fail to capture audio.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        return availableInputDeviceIDs().first { deviceID in
            guard deviceIsAlive(deviceID), deviceHasInputChannels(deviceID) else { return false }
            return transportType(for: deviceID) == .builtIn
        }
    }

    static func resolvedInputDeviceID() -> AudioDeviceID? {
        // The interviewer's chosen microphone wins when it is connected.
        if let preferred = preferredInputDeviceID() { return preferred }

        // Use smart selection: matches input transport type to output
        if let smartID = smartInputDeviceID(),
           deviceIsAlive(smartID),
           deviceHasInputChannels(smartID) {
            return smartID
        }

        // Fallback: any available input device
        return availableInputDeviceIDs().first(where: { deviceIsAlive($0) && deviceHasInputChannels($0) })
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func availableInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs
    }

    static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var alive: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &alive
        )

        return status == noErr && alive != 0
    }

    static func deviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferListPointer
        ) == noErr else {
            return false
        }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferListPointerTyped = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channelCount = bufferListPointerTyped.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channelCount > 0
    }

    /// Force sets a specific input device on the audio engine.
    /// Used for fallback scenarios when the default device selection fails.
    /// - Parameters:
    ///   - deviceID: The device ID to set
    ///   - engine: The audio engine to configure
    /// - Returns: `true` if the device was successfully set
    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else { return false }

        // Verify the device was actually set
        var verifyDeviceID = AudioDeviceID(0)
        var verifySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let verifyStatus = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &verifyDeviceID,
            &verifySize
        )

        return verifyStatus == noErr && verifyDeviceID == deviceID
    }

}
