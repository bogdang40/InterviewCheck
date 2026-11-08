import Foundation
import AppKit
import AVFoundation
import Speech
import ScreenCaptureKit

// MARK: - Permission Manager

final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var accessibilityStatus: PermissionStatus = .notDetermined
    @Published private(set) var microphoneStatus: PermissionStatus = .notDetermined
    @Published private(set) var speechRecognitionStatus: PermissionStatus = .notDetermined
    @Published private(set) var screenRecordingStatus: PermissionStatus = .notDetermined

    private var microphoneRequestTask: Task<PermissionStatus, Never>?
    private var speechRequestTask: Task<PermissionStatus, Never>?

    /// Timestamp of last permission check (stored in UserDefaults for debugging)
    private let lastCheckKey = "memanager.permissions.lastCheck"
    private let permissionHistoryKey = "memanager.permissions.history"
    private let audioPermissionsCompletedKey = "memanager.permissions.audioCompleted"

    /// Tracks whether audio permissions have been granted at least once (so later launches skip the prompt)
    var audioPermissionsCompleted: Bool {
        get { AppDefaults.standard.bool(forKey: audioPermissionsCompletedKey) }
        set { AppDefaults.standard.set(newValue, forKey: audioPermissionsCompletedKey) }
    }

    /// Call this after microphone and speech recognition permissions are granted
    func markAudioPermissionsCompletedIfReady() {
        if microphoneStatus.isGranted && speechRecognitionStatus.isGranted {
            audioPermissionsCompleted = true
            logDebug("Audio permissions marked as completed - later launches skip the prompt")
        }
    }

    private init() {
        Task { @MainActor in
            self.refreshAllStatuses()
        }
    }

    // MARK: - Public Interface

    /// Returns true if all required permissions are granted
    var allPermissionsGranted: Bool {
        accessibilityStatus.isGranted &&
        microphoneStatus.isGranted &&
        speechRecognitionStatus.isGranted &&
        screenRecordingStatus.isGranted
    }

    /// Returns the list of missing permissions
    var missingPermissions: [PermissionType] {
        var missing: [PermissionType] = []
        if !accessibilityStatus.isGranted { missing.append(.accessibility) }
        if !microphoneStatus.isGranted { missing.append(.microphone) }
        if !speechRecognitionStatus.isGranted { missing.append(.speechRecognition) }
        if !screenRecordingStatus.isGranted { missing.append(.screenRecording) }
        return missing
    }

    /// Refreshes all permission statuses
    @MainActor
    func refreshAllStatuses() {
        refreshAccessibilityStatus()
        refreshMicrophoneStatus()
        refreshSpeechRecognitionStatus()
        refreshScreenRecordingStatus()

        // Store last check timestamp
        AppDefaults.standard.set(Date(), forKey: lastCheckKey)

        logDebug("Permissions refreshed - Accessibility: \(accessibilityStatus), Microphone: \(microphoneStatus), Speech: \(speechRecognitionStatus), ScreenRecording: \(screenRecordingStatus)")
    }

    /// Gets the status for a specific permission type
    func status(for permission: PermissionType) -> PermissionStatus {
        switch permission {
        case .accessibility: return accessibilityStatus
        case .microphone: return microphoneStatus
        case .speechRecognition: return speechRecognitionStatus
        case .screenRecording: return screenRecordingStatus
        }
    }

    /// Opens System Settings for a specific permission
    func openSettings(for permission: PermissionType) {
        guard let url = permission.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
        logDebug("Opened system settings for: \(permission.displayName)")
    }

    /// Requests a specific permission (if applicable)
    func requestPermission(_ permission: PermissionType, completion: @escaping (Bool) -> Void) {
        switch permission {
        case .accessibility:
            requestAccessibilityPermission(completion: completion)

        case .microphone:
            Task { @MainActor in
                let status = await requestMicrophonePermissionAsync()
                completion(status.isGranted)
            }

        case .speechRecognition:
            Task { @MainActor in
                let status = await requestSpeechRecognitionPermissionAsync()
                completion(status.isGranted)
            }

        case .screenRecording:
            requestScreenRecordingPermission(completion: completion)
        }
    }

    // MARK: - Accessibility Permission

    @MainActor
    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        self.accessibilityStatus = trusted ? .granted : .denied
    }

    private func requestAccessibilityPermission(completion: @escaping (Bool) -> Void) {
        // Check current status
        if AXIsProcessTrusted() {
            DispatchQueue.main.async {
                self.accessibilityStatus = .granted
                completion(true)
            }
            return
        }

        // Request with prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)

        DispatchQueue.main.async {
            self.accessibilityStatus = result ? .granted : .denied
            completion(result)
        }
    }

    // MARK: - Microphone Permission

    @MainActor
    private func refreshMicrophoneStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            self.microphoneStatus = .granted
        case .denied:
            self.microphoneStatus = .denied
        case .notDetermined:
            self.microphoneStatus = .notDetermined
        case .restricted:
            self.microphoneStatus = .restricted
        @unknown default:
            self.microphoneStatus = .notDetermined
        }
    }

    @MainActor
    func requestMicrophonePermissionAsync(timeoutSeconds: TimeInterval = 8) async -> PermissionStatus {
        refreshMicrophoneStatus()
        if microphoneStatus != .notDetermined {
            return microphoneStatus
        }

        if let task = microphoneRequestTask {
            return await task.value
        }

        let task = Task { () -> PermissionStatus in
            await withCheckedContinuation { continuation in
                var didResume = false

                func finish(_ status: PermissionStatus) {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: status)
                }

                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in
                        self.microphoneStatus = granted ? .granted : .denied
                        finish(self.microphoneStatus)
                    }
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !didResume else { return }
                    self.refreshMicrophoneStatus()
                    finish(self.microphoneStatus)
                }
            }
        }

        microphoneRequestTask = task
        let status = await task.value
        microphoneRequestTask = nil
        return status
    }

    // MARK: - Speech Recognition Permission

    @MainActor
    private func refreshSpeechRecognitionStatus() {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            self.speechRecognitionStatus = .granted
        case .denied:
            self.speechRecognitionStatus = .denied
        case .notDetermined:
            self.speechRecognitionStatus = .notDetermined
        case .restricted:
            self.speechRecognitionStatus = .restricted
        @unknown default:
            self.speechRecognitionStatus = .notDetermined
        }
    }

    @MainActor
    func requestSpeechRecognitionPermissionAsync(timeoutSeconds: TimeInterval = 8) async -> PermissionStatus {
        refreshSpeechRecognitionStatus()
        if speechRecognitionStatus != .notDetermined {
            return speechRecognitionStatus
        }

        if let task = speechRequestTask {
            return await task.value
        }

        let task = Task { () -> PermissionStatus in
            await withCheckedContinuation { continuation in
                var didResume = false

                func finish(_ status: PermissionStatus) {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: status)
                }

                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in
                        switch status {
                        case .authorized:
                            self.speechRecognitionStatus = .granted
                        case .denied:
                            self.speechRecognitionStatus = .denied
                        case .restricted:
                            self.speechRecognitionStatus = .restricted
                        case .notDetermined:
                            self.speechRecognitionStatus = .notDetermined
                        @unknown default:
                            self.speechRecognitionStatus = .notDetermined
                        }
                        finish(self.speechRecognitionStatus)
                    }
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !didResume else { return }
                    self.refreshSpeechRecognitionStatus()
                    finish(self.speechRecognitionStatus)
                }
            }
        }

        speechRequestTask = task
        let status = await task.value
        speechRequestTask = nil
        return status
    }

    // MARK: - Screen Recording Permission

    @MainActor
    func refreshScreenRecordingStatus() {
        // CGPreflightScreenCaptureAccess() returns true if permission is granted
        // Available on macOS 10.15+
        let hasAccess = CGPreflightScreenCaptureAccess()

        let oldStatus = self.screenRecordingStatus
        self.screenRecordingStatus = hasAccess ? .granted : .denied

        // Log permission change if it changed
        if oldStatus != self.screenRecordingStatus {
            self.logPermissionChange(.screenRecording, from: oldStatus, to: self.screenRecordingStatus)
        }
    }

    private func requestScreenRecordingPermission(completion: @escaping (Bool) -> Void) {
        // Use SCShareableContent to check/request ScreenCaptureKit permissions
        // This triggers the correct TCC dialog for "Window & Display Capture"
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                await MainActor.run {
                    self.screenRecordingStatus = .granted
                    completion(true)
                }
            } catch {
                await MainActor.run {
                    self.screenRecordingStatus = .denied
                    completion(false)
                }
            }
        }
    }

    // MARK: - Permission Change Logging

    private func logPermissionChange(_ type: PermissionType, from oldStatus: PermissionStatus, to newStatus: PermissionStatus) {
        let event: [String: String] = [
            "type": type.rawValue,
            "from": oldStatus.displayText,
            "to": newStatus.displayText,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        var history = AppDefaults.standard.array(forKey: permissionHistoryKey) as? [[String: String]] ?? []
        history.append(event)

        // Keep last 50 events
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }

        AppDefaults.standard.set(history, forKey: permissionHistoryKey)
        logDebug("Permission changed: \(type.displayName) \(oldStatus.displayText) -> \(newStatus.displayText)")
    }

    // MARK: - Batch Permission Requests

    /// Requests all permissions that are not yet determined
    func requestAllMissingPermissions(completion: @escaping (Bool) -> Void) {
        let group = DispatchGroup()
        for permission in missingPermissions where status(for: permission) == .notDetermined {
            group.enter()
            requestPermission(permission) { _ in group.leave() }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                self.refreshAllStatuses()
                completion(self.allPermissionsGranted)
            }
        }
    }

    // MARK: - Debug Logging

    private func logDebug(_ message: String) {
        #if DEBUG
        print("[PermissionManager] \(message)")
        #endif
    }
}
